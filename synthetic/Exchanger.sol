pragma solidity ^0.5.16;

import "../common/SafeDecimalMath.sol";
import "../common/Owned.sol";
import "../common/MixinResolver.sol";
import "../interfaces/IVault.sol";
import "../interfaces/ISynthetic.sol";
import "../interfaces/IExchanger.sol";
import "../interfaces/IExchangeRates.sol";
import "../interfaces/ISystemStatus.sol";
import "../interfaces/ISynth.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IMasterChef.sol";

contract Exchanger is Owned, MixinResolver, IExchanger {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    /* ========== STATE VARIABLES ========== */

    // feeRate
    // This could be a little bit different to normal fee rate we know. This is because the unbalancedness in system could be
    // positive or negative. In positive case, system charges fee. Oppositely system rewards fee to account for helping fix unbalancedness.
    uint public feeRate = 3 * SafeDecimalMath.unit() / 1000; //0.3%
    uint public constant MAX_FEE_RATE = 1e18 / 100; //1%

    // balance factor
    // This is the system core factor indicates the unbalancedness between all synths value and eUSD balance of Blackhole
    // We use this to calculate the actual amount of lp or any other synthetic asset minted or burned. Furthermore, we support a mechanism
    // to fix unbalancedness to avoid getting worse.
    uint public balanceFactor = SafeDecimalMath.unit() / 5; //20%
    uint public constant MAX_BALANCE_FACTOR  = 1e18; // 100%

    // This is actual line for zero fee
    uint public zeroFeeLine = SafeDecimalMath.unit() / 10; //10%

    // This indicates when unbalancedness for system reaches this line, stakeToFix is open. Otherwire, stakeToFix is closed.
    uint public fixLine = SafeDecimalMath.unit() / 10; //10%
    uint public constant MAX_LINE = 1e18 / 2; //50%

    bytes32 public constant eUSD = "eUSD";

    ISynth[] public availableSynths;
    mapping(bytes32 => ISynth) public synths;
    mapping(address => bytes32) public synthsByAddress;

    //constants
    bytes32 private constant CONTRACT_VAULT = "Vault";
    bytes32 private constant CONTRACT_SYNTHETIC = "Synthetic";
    bytes32 private constant CONTRACT_SYSTEM = "SystemStatus";
    bytes32 private constant CONTRACT_MASTER_CHEF = "MasterChef";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_BLACKHOLE = "Blackhole";
    bytes32 private constant POOL_NAME = "Synthetic";
    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _resolver
    )
        public
        Owned(_owner)
        MixinResolver(_resolver)
    {
    }

    function vault() internal view returns (IVault) {
        return IVault(resolver.requireAndGetAddress(CONTRACT_VAULT, "Missing Vault address"));
    }

    function exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(resolver.requireAndGetAddress(CONTRACT_EXRATES, "Missing ExchangeRates address"));
    }

    function systemStatus() internal view returns (ISystemStatus) {
        return ISystemStatus(resolver.requireAndGetAddress(CONTRACT_SYSTEM, "Missing SystemStatus address"));
    }

    function synthetic() internal view returns (ISynthetic) {
        return ISynthetic(resolver.requireAndGetAddress(CONTRACT_SYNTHETIC, "Missing Synthetic address"));
    }

    function masterChef() internal view returns (IMasterChef) {
        return IMasterChef(resolver.requireAndGetAddress(CONTRACT_MASTER_CHEF, "Missing MasterChef address"));
    }

    function blackhole() internal view returns (address) {
        return resolver.requireAndGetAddress(CONTRACT_BLACKHOLE, "Missing Blackhole address");
    }

    /* ========== SETTERS ============ */
    function setFeeRate(uint _feeRate) external onlyOwner {
        require(_feeRate <= MAX_FEE_RATE, "New fee rate cannot exceed MAX_FEE_RATE");
        feeRate = _feeRate;
        emit FeeRateUpdated(_feeRate);
    }

    function setBalanceFactor(uint _balanceFactor) external onlyOwner {
        require(_balanceFactor <= MAX_BALANCE_FACTOR, "New balance factor cannot exceed MAX_BALANCE_FACTOR");
        balanceFactor = _balanceFactor;
        emit BalanceFactorUpdated(_balanceFactor);
    }

    function setZeroFeeLine(uint _zeroFeeLine) external onlyOwner {
        require(_zeroFeeLine <= MAX_LINE, "New zero fee line cannot exceed MAX_LINE");
        zeroFeeLine = _zeroFeeLine;
        emit ZeroFeeLineUpdated(_zeroFeeLine);
    }

    function setFixLine(uint _fixLine) external onlyOwner {
        require(_fixLine <= MAX_LINE, "New fix line cannot exceed MAX_LINE");
        fixLine = _fixLine;
        emit FixLineUpdated(_fixLine);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function addSynth(ISynth synth) external onlyOwner {
        bytes32 currencyKey = synth.currencyKey();

        require(synths[currencyKey] == ISynth(0), "Synth already exists");
        require(synthsByAddress[address(synth)] == bytes32(0), "Synth address already exists");

        availableSynths.push(synth);
        synths[currencyKey] = synth;
        synthsByAddress[address(synth)] = currencyKey;

        emit SynthAdded(currencyKey, address(synth));
    }

    function removeSynth(bytes32 currencyKey) external onlyOwner {
        require(address(synths[currencyKey]) != address(0), "Synth does not exist");
        require(IERC20(address(synths[currencyKey])).totalSupply() == 0, "Synth supply exists");

        // Save the address we're removing for emitting the event at the end.
        address synthToRemove = address(synths[currencyKey]);

        // Remove the synth from the availableSynths array.
        for (uint i = 0; i < availableSynths.length; i++) {
            if (address(availableSynths[i]) == synthToRemove) {
                delete availableSynths[i];

                // Copy the last synth into the place of the one we just deleted
                // If there's only one synth, this is synths[0] = synths[0].
                // If we're deleting the last one, it's also a NOOP in the same way.
                availableSynths[i] = availableSynths[availableSynths.length - 1];

                // Decrease the size of the array by one.
                availableSynths.length--;

                break;
            }
        }

        // And remove it from the synths mapping
        delete synthsByAddress[address(synths[currencyKey])];
        delete synths[currencyKey];

        emit SynthRemoved(currencyKey, synthToRemove);
    }

    function exchange(address from, bytes32 sourceKey, uint amount, bytes32 destKey) external onlySynthetic synthActive(sourceKey, destKey) returns (uint received)  {
        require(either(sourceKey == eUSD, destKey == eUSD), "SourceKey or destKey must be eUSD");

        //check if rate is stale
        bytes32[] memory synthKeys = new bytes32[](2);
        synthKeys[0] = sourceKey;
        synthKeys[1] = destKey;
        require(!exchangeRates().anyRateIsStale(synthKeys), "Src/dest rate stale or not found");

        if (sourceKey != eUSD) {
            uint balance = IERC20(address(synths[sourceKey])).balanceOf(from);
            require(amount <= balance, "Insufficient balance to exchange");
        }

        received = exchangeRates().effectiveValue(sourceKey, amount, destKey);
        (uint rate, bool positive) = _currentFeeRate();
        if (rate > 0) {
            received = positive ? (received.multiplyDecimalRound(SafeDecimalMath.unit().add(rate))) : (received.multiplyDecimalRound(SafeDecimalMath.unit().sub(rate)));
        }

        if (sourceKey != eUSD) {
            synths[sourceKey].burn(from, amount);
        } else {
            synths[destKey].issue(from, received);
        }

        return received;
    }

    /* ========== VIEWS ============ */
    function canFix() external view returns (bool canFix) {
        (uint curLine, bool positive, bool anyRateIsStale) = _currentLine();
        if (both(!positive, !anyRateIsStale)) {
            if (curLine > fixLine) {
                canFix = true;
            }
        }
    }

    //Returns max eUSD can stake to fix system's unbalanceness
    function maxAmountToFix() external view returns (uint maxAmount) {
        (uint blackholeBalance, uint totalValue, bool anyRateIsStale) = _balanceAndLP();
        if (totalValue > blackholeBalance && !anyRateIsStale) {
            uint curLine = SafeDecimalMath.unit().sub(blackholeBalance.divideDecimalRound(totalValue));
            if (curLine > fixLine) {
                 maxAmount = SafeDecimalMath.unit().sub(fixLine).multiplyDecimalRound(totalValue).sub(blackholeBalance);
            }
        }
    }

    //Calculates amount of eUSD returned by amount of LP
    function calAmountFromBlackhole(uint amount) external view returns (uint, bool) {
        (uint blackholeBalance, uint totalValue, bool anyRateIsStale) = _balanceAndLP();
        if (amount == totalValue) {
            return (blackholeBalance, anyRateIsStale);
        }

        return (blackholeBalance.divideDecimalRound(totalValue).multiplyDecimalRound(amount), anyRateIsStale);
    }

    //Calculates amount of LP minted by amount of eUSD
    function calAmountToBlackhole(uint amount) external view returns (uint, bool) {
        (uint blackholeBalance, uint totalValue, bool anyRateIsStale) = _balanceAndLP();

        uint lpAmount = 0;
        //If blackholeBalance equals 0. we assume totalValue equals 0 too.
        //Otherwise, if totalValue equals 0, blackholeBalance could be greater than 0 for fee distributed by vault.
        //If both are positive, we use ratio * amount to get the actual lp amount.
        //ratio = totalValue / blackholeBalance.
        if (blackholeBalance == 0) {
            lpAmount = amount;
        } else {
            if (totalValue == 0) {
                lpAmount = blackholeBalance.add(amount);
            } else {
                lpAmount = totalValue.divideDecimalRound(blackholeBalance).multiplyDecimalRound(amount);
            }
        }

        return (lpAmount, anyRateIsStale);
    }

    function currentFeeRate() external view returns (uint rate, bool positive) {
        (rate, positive) = _currentFeeRate();
    }

    //Returns current balance factor, the second value represents the balance factor is positive or negtive.
    function currentBalanceFactor() external view returns (uint factor) {
        (factor, ) = _currentBalanceFactor();
    }

    function totalIssuedSynthsAndLP() external returns (uint totalIssued) {
        (totalIssued, ) = _totalIssuedSynthsAndLP();
    }

    function totalIssuedSynths() external view returns (uint totalIssued) {
        (totalIssued, ) = _totalIssuedSynths();
    }

    function _currentFeeRate() internal view returns (uint, bool) {
        (uint factor, bool positive) = _currentBalanceFactor();
        uint rate = 0;

        if (factor == 0) {
            rate = 0;
        } else {
            rate = factor.divideDecimalRound(balanceFactor).multiplyDecimalRound(feeRate);
        }

        return (rate, positive);
    }

    function _currentBalanceFactor() internal view returns (uint factor, bool isPositive) {
        (uint curLine, bool positive, ) = _currentLine();

        uint baseLine = _baseLine();
        if (positive) {
            if (curLine >= zeroFeeLine) {
                factor = curLine.sub(zeroFeeLine).divideDecimalRound(baseLine);
                isPositive = true;
            } else {
                factor = zeroFeeLine.sub(curLine).divideDecimalRound(baseLine);
            }
        } else {
            factor = zeroFeeLine.add(curLine).divideDecimalRound(baseLine);
        }

        if (factor > balanceFactor) {
            factor = balanceFactor;
        }
    }

    function _baseLine() internal view returns (uint) {
        return SafeDecimalMath.unit().add(zeroFeeLine);
    }

    function _currentLine() internal view returns (uint, bool, bool) {
        uint blackholeBalance = vault().collateral(address(blackhole()));
        (uint totalValue, bool anyRateIsStale) = _totalIssuedSynthsAndLP();
        //No unbalancedness
        if (either(blackholeBalance == totalValue, either(blackholeBalance == 0, totalValue == 0))) {
            return (0, true, anyRateIsStale);
        }

        uint curLine = 0;
        bool positive = true;
        if (blackholeBalance > totalValue) {
            curLine = blackholeBalance.divideDecimalRound(totalValue).sub(SafeDecimalMath.unit());
        } else {
            curLine = SafeDecimalMath.unit().sub(blackholeBalance.divideDecimalRound(totalValue));
            positive = false;
        }

        return (curLine, positive, anyRateIsStale);
    }

    function _balanceAndLP() internal view returns (uint blackholeBalance, uint totalValue, bool anyRateIsStale) {
        blackholeBalance = vault().collateral(address(blackhole()));
        (totalValue, anyRateIsStale) = _totalIssuedSynthsAndLP();
    }

    function _totalIssuedSynthsAndLP() internal view returns (uint, bool) {
        (uint totalIssued, bool anyRateIsStale) = _totalIssuedSynths();

        (uint totalLP, , ,) = masterChef().getPoolInfo(POOL_NAME);
        return (totalLP.add(totalIssued), anyRateIsStale);
    }

    function _totalIssuedSynths() internal view returns (uint totalIssued, bool anyRateIsStale)
    {
        uint total = 0;
        uint currencyRate;

        bytes32[] memory currencyKeys = new bytes32[](availableSynths.length);

        for (uint i = 0; i < availableSynths.length; i++) {
            currencyKeys[i] = synthsByAddress[address(availableSynths[i])];
        }

        // In order to reduce gas usage, fetch all rates and stale at once
        (uint[] memory rates, bool anyRateStale) = exchangeRates().ratesAndStaleForCurrencies(currencyKeys);

        // Then instead of invoking exchangeRates().effectiveValue() for each synth, use the rate already fetched
        for (uint i = 0; i < currencyKeys.length; i++) {
            bytes32 synth = currencyKeys[i];
            uint totalSynths = IERC20(address(synths[synth])).totalSupply();

            uint synthValue = totalSynths.multiplyDecimalRound(rates[i]);
            total = total.add(synthValue);
        }

        return (total, anyRateStale);
    }

    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    /* ========== MODIFIERS ========== */
    modifier onlySynthetic {
        require(msg.sender == address(synthetic()), "Only Synthetic contract can invoke this function");
        _;
    }

    modifier synthActive(bytes32 sourceKey, bytes32 destKey) {
        systemStatus().requireExchangeActive();
        systemStatus().requireSynthActive(sourceKey);
        systemStatus().requireSynthActive(destKey);
        _;
    }

    /* ========== EVENTS ========== */
    event FeeRateUpdated(uint newRate);

    event BalanceFactorUpdated(uint newFactor);

    event ZeroFeeLineUpdated(uint newFeeLine);

    event FixLineUpdated(uint newFixLine);

    event SynthAdded(bytes32 currencyKey, address synth);

    event SynthRemoved(bytes32 currencyKey, address synth);
}
