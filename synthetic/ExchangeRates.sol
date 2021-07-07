pragma solidity ^0.5.16;

import "../common/SafeDecimalMath.sol";
import "../common/Owned.sol";
import "../common/SelfDestructible.sol";
import "../interfaces/IExchangeRates.sol";
import "../interfaces/IOracleProxy.sol";
import "openzeppelin-solidity-2.3.0/contracts/math/SafeMath.sol";

/**
 * @title The repository for exchange rates
 */

contract ExchangeRates is Owned, SelfDestructible, IExchangeRates {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    struct RateAndUpdatedTime {
        uint216 rate;
        uint40 time;
    }

    //OracleInfo stores Decentralized oracle info for id and symbol.
    //id is used to specify the given oracle, symbol is the queried price symbol, for example lamb_usdt.
    struct OracleInfo {
        uint256 ocID;
        bytes32 symbol;
    }

    // Exchange rates and update times stored by currency code, e.g. 'ETHC', or 'eUSD'
    mapping(bytes32 => mapping(uint => RateAndUpdatedTime)) private _rates;

    // The address of the oracle which pushes rate updates to this contract
    address public oracle;

    //The address of the oracle proxy contract address to query the synthetic asset's price
    address public oracleProxy;

    // Decentralized oracle networks that feed into pricing oracle.
    mapping(bytes32 => OracleInfo) public oracleInfos;

    // Do not allow the oracle to submit times any further forward into the future than this constant.
    uint private constant ORACLE_FUTURE_LIMIT = 10 minutes;

    // How long will the contract assume the rate of any asset is correct
    uint public rateStalePeriod = 3 hours;

    mapping(bytes32 => uint) currentRoundForRate;

    //
    // ========== CONSTRUCTOR ==========

    /**
     * @dev Constructor
     * @param _owner The owner of this contract.
     * @param _oracle The address which is able to update rate information.
     * @param _currencyKeys The initial currency keys to store (in order).
     * @param _newRates The initial currency amounts for each currency (in order).
     */
    constructor(
        // SelfDestructible (Ownable)
        address _owner,
        // Oracle values - Allows for rate updates
        address _oracle,
        address _oracleProxy,
        bytes32[] memory _currencyKeys,
        uint[] memory _newRates
    )
        public
        Owned(_owner)
        SelfDestructible()
    {
        require(_oracle != address(0), "oracle address cannot be 0");
        require(_oracleProxy != address(0), "oracleProxy address cannot be 0");
        require(_currencyKeys.length == _newRates.length, "Currency key length and rate length must match.");

        oracle = _oracle;

        oracleProxy = _oracleProxy;

        // The eUSD rate is always 1 and is never stale.
        _setRate("eUSD", SafeDecimalMath.unit(), now);

        internalUpdateRates(_currencyKeys, _newRates, now);
    }

    /* ========== SETTERS ========== */

    /**
     * @notice Set the Oracle that pushes the rate information to this contract
     * @param _oracle The new oracle address
     */
    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "_oracle can not be 0");
        oracle = _oracle;
        emit OracleUpdated(_oracle);
    }

    function setOracleProxy(address _oracleProxy) external onlyOwner {
        require(_oracleProxy != address(0), "_oracleProxy can not be 0");
        oracleProxy = _oracleProxy;
        emit OracleProxyUpdated(_oracleProxy);
    }

    /**
     * @notice Set the stale period on the updated rate variables
     * @param _time The new rateStalePeriod
     */
    function setRateStalePeriod(uint _time) external onlyOwner {
        rateStalePeriod = _time;
        emit RateStalePeriodUpdated(rateStalePeriod);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Set the rates stored in this contract
     * @param currencyKeys The currency keys you wish to update the rates for (in order)
     * @param newRates The rates for each currency (in order)
     * @param timeSent The timestamp of when the update was sent, specified in seconds since epoch (e.g. the same as the now keyword in solidity).
     *                 This is useful because transactions can take a while to confirm, so this way we know how old the oracle's datapoint was exactly even
     *                 if it takes a long time for the transaction to confirm.
     */
    function updateRates(bytes32[] calldata currencyKeys, uint[] calldata newRates, uint timeSent) external onlyOracle returns (bool) {
        return internalUpdateRates(currencyKeys, newRates, timeSent);
    }

    /**
     * @notice Delete a rate stored in the contract
     * @param currencyKey The currency key you wish to delete the rate for
     */
    function deleteRate(bytes32 currencyKey) external onlyOracle {
        require(getRate(currencyKey) > 0, "Rate is 0");

        delete _rates[currencyKey][currentRoundForRate[currencyKey]];

        currentRoundForRate[currencyKey]--;

        emit RateDeleted(currencyKey);
    }

    /**
     * @notice Add a pricing oracle info for the given key.
     * @param currencyKey The currency key to add an oracle info for
     */
    function addOracleInfo(bytes32 currencyKey, uint256 _ocID, bytes32 _symbol) external onlyOwner {
        require(_ocID > 0, "_ocID cannot be 0");

        IOracleProxy proxy = IOracleProxy(oracleProxy);
        (address oracleAddr, , ) = proxy.getOracleInfo(_ocID);
        require(oracleAddr != address(0), "Invalid oracle");

        oracleInfos[currencyKey] = OracleInfo({
            ocID: _ocID,
            symbol: _symbol
        });

        emit OracleInfoAdded(currencyKey, oracleAddr, _ocID, _symbol);
    }

    /**
     * @notice Remove a pricing oracle info for the given key
     * @param currencyKey The currency key to remove an oracle info for
     */
    function removeOracleInfo(bytes32 currencyKey) external onlyOwner {
        OracleInfo memory oracleInfo = oracleInfos[currencyKey];
        require(oracleInfo.ocID > 0, "No oracle exists for key");

        IOracleProxy proxy = IOracleProxy(oracleProxy);
        (address oracleAddr, , ) = proxy.getOracleInfo(oracleInfo.ocID);
        delete oracleInfos[currencyKey];

        emit OracleInfoRemoved(currencyKey, oracleAddr, oracleInfo.ocID, oracleInfo.symbol);
    }

    function getLastRoundIdBeforeElapsedSecs(
        bytes32 currencyKey,
        uint startingRoundId,
        uint startingTimestamp,
        uint timediff
    ) external view returns (uint) {
        uint roundId = startingRoundId;
        uint nextTimestamp = 0;
        while (true) {
            (, nextTimestamp) = getRateAndTimestampAtRound(currencyKey, roundId + 1);
            // if there's no new round, then the previous roundId was the latest
            if (nextTimestamp == 0 || nextTimestamp > startingTimestamp + timediff) {
                return roundId;
            }
            roundId++;
        }
        return roundId;
    }

    function getCurrentRoundId(bytes32 currencyKey) external view returns (uint) {
        OracleInfo memory oracleInfo = oracleInfos[currencyKey];

        if (oracleInfo.ocID > 0) {
            (, , , uint64 id) = IOracleProxy(oracleProxy).getCoinInfo(oracleInfo.ocID, oracleInfo.symbol);
            return uint(id);
        } else {
            return currentRoundForRate[currencyKey];
        }
    }

    function effectiveValueAtRound(
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey,
        uint roundIdForSrc,
        uint roundIdForDest
    ) external view rateNotStale(sourceCurrencyKey) rateNotStale(destinationCurrencyKey) returns (uint) {
        // If there's no change in the currency, then just return the amount they gave us
        if (sourceCurrencyKey == destinationCurrencyKey) return sourceAmount;

        (uint srcRate, ) = getRateAndTimestampAtRound(sourceCurrencyKey, roundIdForSrc);
        (uint destRate, ) = getRateAndTimestampAtRound(destinationCurrencyKey, roundIdForDest);
        // Calculate the effective value by going from source -> USD -> destination
        return sourceAmount.multiplyDecimalRound(srcRate).divideDecimalRound(destRate);
    }

    function rateAndTimestampAtRound(bytes32 currencyKey, uint roundId) external view returns (uint rate, uint time) {
        return getRateAndTimestampAtRound(currencyKey, roundId);
    }

    /* ========== VIEWS ========== */

    /**
     * @notice Retrieves the timestamp the given rate was last updated.
     */
    function lastRateUpdateTimes(bytes32 currencyKey) public view returns (uint256) {
        return getRateAndUpdatedTime(currencyKey).time;
    }

    /**
     * @notice Retrieve the last update time for a list of currencies
     */
    function lastRateUpdateTimesForCurrencies(bytes32[] calldata currencyKeys) external view returns (uint[] memory) {
        uint[] memory lastUpdateTimes = new uint[](currencyKeys.length);

        for (uint i = 0; i < currencyKeys.length; i++) {
            lastUpdateTimes[i] = lastRateUpdateTimes(currencyKeys[i]);
        }

        return lastUpdateTimes;
    }

    /**
     * @notice A function that lets you easily convert an amount in a source currency to an amount in the destination currency
     * @param sourceCurrencyKey The currency the amount is specified in
     * @param sourceAmount The source amount, specified in UNIT base
     * @param destinationCurrencyKey The destination currency
     */
    function effectiveValue(bytes32 sourceCurrencyKey, uint sourceAmount, bytes32 destinationCurrencyKey)
        public
        view
        rateNotStale(sourceCurrencyKey)
        rateNotStale(destinationCurrencyKey)
        returns (uint)
    {
        // If there's no change in the currency, then just return the amount they gave us
        if (sourceCurrencyKey == destinationCurrencyKey) return sourceAmount;

        // Calculate the effective value by going from source -> USD -> destination
        return
            sourceAmount.multiplyDecimalRound(getRate(sourceCurrencyKey)).divideDecimalRound(
                getRate(destinationCurrencyKey)
            );
    }

    /**
     * @notice Retrieve the rate for a specific currency
     */
    function rateForCurrency(bytes32 currencyKey) external view returns (uint) {
        return getRateAndUpdatedTime(currencyKey).rate;
    }

    /**
     * @notice Retrieve the rates for a list of currencies
     */
    function ratesForCurrencies(bytes32[] calldata currencyKeys) external view returns (uint[] memory) {
        uint[] memory _localRates = new uint[](currencyKeys.length);

        for (uint i = 0; i < currencyKeys.length; i++) {
            _localRates[i] = getRate(currencyKeys[i]);
        }

        return _localRates;
    }

    /**
     * @notice Retrieve the rates and isAnyStale for a list of currencies
     */
    function ratesAndStaleForCurrencies(bytes32[] calldata currencyKeys) external view returns (uint[] memory, bool) {
        uint[] memory _localRates = new uint[](currencyKeys.length);

        bool anyRateStale = false;
        uint period = rateStalePeriod;
        for (uint i = 0; i < currencyKeys.length; i++) {
            RateAndUpdatedTime memory rateAndUpdateTime = getRateAndUpdatedTime(currencyKeys[i]);
            _localRates[i] = uint256(rateAndUpdateTime.rate);
            if (!anyRateStale) {
                anyRateStale = (currencyKeys[i] != "eUSD" && uint256(rateAndUpdateTime.time).add(period) < now);
            }
        }

        return (_localRates, anyRateStale);
    }

    /**
     * @notice Check if a specific currency's rate hasn't been updated for longer than the stale period.
     */
    function rateIsStale(bytes32 currencyKey) public view returns (bool) {
        // eUSD is a special case and is never stale.
        if (currencyKey == "eUSD") return false;

        return lastRateUpdateTimes(currencyKey).add(rateStalePeriod) < now;
    }

    /**
     * @notice Check if any of the currency rates passed in haven't been updated for longer than the stale period.
     */
    function anyRateIsStale(bytes32[] calldata currencyKeys) external view returns (bool) {
        // Loop through each key and check whether the data point is stale.
        uint256 i = 0;

        while (i < currencyKeys.length) {
            // eUSD is a special case and is never false
            if (currencyKeys[i] != "eUSD" && lastRateUpdateTimes(currencyKeys[i]).add(rateStalePeriod) < now) {
                return true;
            }
            i += 1;
        }

        return false;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _setRate(bytes32 currencyKey, uint256 rate, uint256 time) internal {
        // Note: this will effectively start the rounds at 1, which matches Chainlink's Agggregators
        currentRoundForRate[currencyKey]++;

        _rates[currencyKey][currentRoundForRate[currencyKey]] = RateAndUpdatedTime({
            rate: uint216(rate),
            time: uint40(time)
        });
    }

    /**
     * @notice Internal function which sets the rates stored in this contract
     * @param currencyKeys The currency keys you wish to update the rates for (in order)
     * @param newRates The rates for each currency (in order)
     * @param timeSent The timestamp of when the update was sent, specified in seconds since epoch (e.g. the same as the now keyword in solidity).contract
     *                 This is useful because transactions can take a while to confirm, so this way we know how old the oracle's datapoint was exactly even
     *                 if it takes a long time for the transaction to confirm.
     */
    function internalUpdateRates(bytes32[] memory currencyKeys, uint[] memory newRates, uint timeSent) internal returns (bool) {
        require(currencyKeys.length == newRates.length, "Currency key array length must match rates array length.");
        require(timeSent < (now + ORACLE_FUTURE_LIMIT), "Time is too far into the future");

        // Loop through each key and perform update.
        for (uint i = 0; i < currencyKeys.length; i++) {
            bytes32 currencyKey = currencyKeys[i];

            // Should not set any rate to zero ever, as no asset will ever be
            // truely worthless and still valid. In this scenario, we should
            // delete the rate and remove it from the system.
            require(newRates[i] != 0, "Zero is not a valid rate, please call deleteRate instead.");
            require(currencyKey != "eUSD", "Rate of eUSD cannot be updated, it's always UNIT.");

            // We should only update the rate if it's at least the same age as the last rate we've got.
            if (timeSent < lastRateUpdateTimes(currencyKey)) {
                continue;
            }

            // Ok, go ahead with the update.
            _setRate(currencyKey, newRates[i], timeSent);
        }

        emit RatesUpdated(currencyKeys, newRates);

        return true;
    }

    function getRateAndUpdatedTime(bytes32 currencyKey) internal view returns (RateAndUpdatedTime memory) {
        OracleInfo memory oracleInfo = oracleInfos[currencyKey];

        if (oracleInfo.ocID > 0) {
            (, int _rate, uint64 _time, ) = IOracleProxy(oracleProxy).getCoinInfo(oracleInfo.ocID, oracleInfo.symbol);
            return
                RateAndUpdatedTime({
                    rate: uint216(_rate),
                    time: uint40(_time)
                });
        } else {
            return _rates[currencyKey][currentRoundForRate[currencyKey]];
        }
    }

    function getRateAndTimestampAtRound(bytes32 currencyKey, uint roundId) internal view returns (uint, uint) {
        OracleInfo memory oracleInfo = oracleInfos[currencyKey];

        if (oracleInfo.ocID > 0) {
            (, int _rate, uint64 _time, ) = IOracleProxy(oracleProxy).getCoinInfoById(oracleInfo.ocID, oracleInfo.symbol, uint64(roundId));
            return (uint(_rate), uint(_time));
        } else {
            RateAndUpdatedTime storage update = _rates[currencyKey][roundId];
            return (update.rate, update.time);
        }
    }

    function getRate(bytes32 currencyKey) internal view returns (uint256) {
        return getRateAndUpdatedTime(currencyKey).rate;
    }

    /* ========== MODIFIERS ========== */

    modifier rateNotStale(bytes32 currencyKey) {
        require(!rateIsStale(currencyKey), "Rate stale or nonexistant currency");
        _;
    }

    modifier onlyOracle {
        require(msg.sender == oracle, "Only the oracle can perform this action");
        _;
    }

    /* ========== EVENTS ========== */

    event OracleUpdated(address newOracle);
    event OracleProxyUpdated(address newProxy);
    event RateStalePeriodUpdated(uint rateStalePeriod);
    event RatesUpdated(bytes32[] currencyKeys, uint[] newRates);
    event RateDeleted(bytes32 currencyKey);
    event OracleInfoAdded(bytes32 currencyKey, address oracle, uint256 ocID, bytes32 symbol);
    event OracleInfoRemoved(bytes32 currencyKey, address oracle, uint256 ocID, bytes32 symbol);
}
