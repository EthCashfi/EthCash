pragma solidity ^0.5.16;

import "../common/SafeDecimalMath.sol";
import "../common/Math.sol";
import "../common/Owned.sol";
import "../common/MixinResolver.sol";
import "../interfaces/IExchanger.sol";
import "../interfaces/IExchangeRates.sol";
import "../interfaces/ISystemStatus.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/ISynthetic.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IVault.sol";

contract Synthetic is Owned, MixinResolver, ISynthetic {
    using SafeMath for uint;
    using SafeDecimalMath for uint;
    using Math for uint;

    /* ========== STATE VARIABLES ========== */

    uint public discount = SafeDecimalMath.unit() / 10; //10%
    uint public constant MAX_DISCOUNT = 1e18 / 5; //20%

    uint public feeRate = SafeDecimalMath.unit() / 10; //10%
    uint public constant MAX_FEE_RATE = 1e18 / 2; //50%

    bytes32 private constant eUSD = "eUSD";
    bytes32 private constant ETHC = "ETHC";

    // Max
    uint public constant MAX_MIN_JOIN_DURATION = 1 weeks;

    uint public minJoinDuration = 24 hours; //jon and exit minimum interval

    // Fix Fee
    // Reduce to half after 720mins
    uint constant public SECONDS_IN_ONE_MINUTE = 60;

    uint constant public MINUTE_DECAY_FACTOR = 999037758833783000;

    uint constant public FEE_FACTOR = 1e18 * 100;

    uint public fixFeeRate;

    //Last fix operation time
    uint public lastOperationTime;

    //constants
    bytes32 private constant CONTRACT_VAULT = "Vault";
    bytes32 private constant CONTRACT_EXCHANGER = "Exchanger";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_SYSTEM = "SystemStatus";
    bytes32 private constant CONTRACT_MASTER_CHEF = "MasterChef";
    bytes32 private constant CONTRACT_BLACKHOLE = "Blackhole";
    bytes32 private constant POOL_NAME = "Synthetic";

    //User Last Event records user's last join event timestamp
    mapping(address => uint) internal lastJoinEvent;

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

    function vault() internal view returns (address) {
        return resolver.requireAndGetAddress(CONTRACT_VAULT, "Missing Vault address");
    }

    function exchanger() internal view returns (IExchanger) {
        return IExchanger(resolver.requireAndGetAddress(CONTRACT_EXCHANGER, "Missing Exchanger address"));
    }

    function exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(resolver.requireAndGetAddress(CONTRACT_EXRATES, "Missing ExchangeRates address"));
    }

    function systemStatus() internal view returns (ISystemStatus) {
        return ISystemStatus(resolver.requireAndGetAddress(CONTRACT_SYSTEM, "Missing SystemStatus address"));
    }

    function blackhole() internal view returns (address) {
        return resolver.requireAndGetAddress(CONTRACT_BLACKHOLE, "Missing Blackhole address");
    }

    function masterChef() internal view returns (IMasterChef) {
        return IMasterChef(resolver.requireAndGetAddress(CONTRACT_MASTER_CHEF, "Missing MasterChef address"));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function setDiscount(uint _discount) external onlyOwner {
        require(_discount <= MAX_DISCOUNT, "New discount cannot exceed MAX_DISCOUNT");
        discount = _discount;
        emit DiscountUpdated(_discount);
    }

    function setFeeRate(uint _feeRate) external onlyOwner {
        require(_feeRate <= MAX_FEE_RATE, "New fee ratio cannot exceed MAX_FEE_RATE");
        feeRate = _feeRate;
        emit FeeRateUpdated(_feeRate);
    }

    function setMinJoinDuration(uint _duration) external onlyOwner {
        require(_duration <= MAX_MIN_JOIN_DURATION, "join duration exceed maximum 1 week");
        minJoinDuration = _duration;
        emit MinJoinDurationUpdated(_duration);
    }

    //Calls stake will send amount of eUSD to Synthetic system then will have lp token record in system.
    //User can use lp token to exchange and mint real synthetic assets. Also lp token holder will
    //receive a mintable token reward constantly.
    function stake(address account, uint amount) external onlyVault syntheticActive returns (uint) {
        (uint lpAmount, bool anyRateIsStale) = exchanger().calAmountToBlackhole(amount);
        require(!anyRateIsStale, "A synth rate is stale");

        masterChef().add(POOL_NAME, account, lpAmount);
        lastJoinEvent[account] = block.timestamp;

        return lpAmount;
    }

    //Calls this will sub amount of lp token record from system and receive amount of eUSD based on the system
    //status.
    function exit(address account, uint amount) external onlyVault syntheticActive returns (uint) {
        require(now >= lastJoinEvent[account].add(minJoinDuration), "Min join time not reached");

        (uint existLpAmount, ,) = masterChef().getUserInfo(POOL_NAME, account);
        require(existLpAmount >= amount, "Not enough amount");

        (uint eUSDAmount, bool anyRateIsStale) = exchanger().calAmountFromBlackhole(amount);
        require(!anyRateIsStale, "A synth rate is stale");

        masterChef().sub(POOL_NAME, account, amount);

        return eUSDAmount;
    }

    //This can only be call when system is unbalanced and helps the system return balance
    //TotalStaked(eUSD) < TotalSynthsValue(lp + synth).
    //User will send amount of eUSD to Synthetic system, then system will mint amount of token reward.
    //Fix fee will reduce ETHC received, it will decay by time and increase when fix operation happen
    function fix(address account, uint amount, uint maxFee) external onlyVault syntheticActive returns (uint) {
        IExchanger exchanger = exchanger();
        require(exchanger.canFix(), "Can not stake to fix unbalanceness");
        require(amount <= exchanger.maxAmountToFix(), "Amount exceeds Max");
        require(both(maxFee > 0, maxFee <= SafeDecimalMath.unit()), "MaxFee must be between 0 to 1");

        uint mintAmount = exchangeRates().effectiveValue(eUSD, amount.multiplyDecimalRound(SafeDecimalMath.unit().add(discount)), ETHC);
        uint rate = _updateFixFeeRate(mintAmount);
        require(rate <= maxFee, "Fee exceeded max fee");

        uint receivedAmount = mintAmount.multiplyDecimalRound(SafeDecimalMath.unit().sub(rate));
        if (receivedAmount > 0) {
            masterChef().mintEthC(POOL_NAME, account, receivedAmount);
        }

        return receivedAmount;
    }

    //Calls this will burn real synthetic asset to lp token or mint synthetic asset and
    //reduce lp token from system according to asset's price
    function exchange(address account, bytes32 sourceKey, uint amount, bytes32 destKey) external onlyVault returns (uint) {
        if (sourceKey == eUSD) {
            (uint existLpAmount, ,) = masterChef().getUserInfo(POOL_NAME, account);
            require(existLpAmount >= amount, "Not enough amount");
        }

        uint destAmount = exchanger().exchange(account, sourceKey, amount, destKey);
        if (sourceKey == eUSD) {
            masterChef().sub(POOL_NAME, account, amount);
        } else {
            masterChef().add(POOL_NAME, account, destAmount);
        }

        return destAmount;
    }

    //charge withdraw ETHC fee by eUSD
    function chargeWithdrawFee(address account, uint amount) external onlyMasterChef returns (uint) {
        require(amount > 0, "amount cannot be 0");
        uint ethCAmount = exchangeRates().effectiveValue(ETHC, amount, eUSD);

        uint feeCharged = ethCAmount.multiplyDecimalRound(feeRate);
        IVault(vault()).chargeFee(account, feeCharged);

        return feeCharged;
    }

    function _updateFixFeeRate(uint amount) internal returns (uint) {
        uint decayedFixFeeRate = _calcDecayedFixFeeRate();

        uint totalSupply = IERC20(masterChef().ethCash()).totalSupply();
        uint fraction = amount.divideDecimalRound(totalSupply).multiplyDecimalRound(FEE_FACTOR);

        uint newFixFeeRate = decayedFixFeeRate.add(fraction);
        if (newFixFeeRate > SafeDecimalMath.unit()) {
            newFixFeeRate = SafeDecimalMath.unit();
        }

        require(newFixFeeRate > 0, "new fix fee rate must be positive");

        fixFeeRate = newFixFeeRate;
        emit FixFeeRateUpdated(newFixFeeRate);

        _updateLastOpTime();

        return newFixFeeRate;
    }

    function _updateLastOpTime() internal {
        uint timePassed = block.timestamp.sub(lastOperationTime);

        if (timePassed >= SECONDS_IN_ONE_MINUTE) {
            lastOperationTime = block.timestamp;
            emit LastOpTimeUpdated(block.timestamp);
        }
    }

    // util
    function stringToBytes32(string memory source) public pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }

        assembly {
            result := mload(add(source, 32))
        }
    }

     function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    /* ========== VIEWS ============ */
    //Returns max exitable eUSD currently according to lp amount
    function maxExitableAmount(address account) external view returns (uint eUSDAmount) {
        (uint existLpAmount, ,) = masterChef().getUserInfo(POOL_NAME, account);
        (eUSDAmount, ) = exchanger().calAmountFromBlackhole(existLpAmount);
    }

    function getFixFeeRateWithDecay() public view returns (uint) {
        return _calcDecayedFixFeeRate();
    }

    function _calcDecayedFixFeeRate() internal view returns (uint) {
        uint minutesPassed = _minutesPassedSinceLastOp();
        uint decayFactor = MINUTE_DECAY_FACTOR.powDecimal(minutesPassed);

        return fixFeeRate.multiplyDecimalRound(decayFactor);
    }

    function _minutesPassedSinceLastOp() internal view returns (uint) {
        return (block.timestamp.sub(lastOperationTime)).div(SECONDS_IN_ONE_MINUTE);
    }

    /* ========== MODIFIERS ========== */
    modifier onlyVault {
        require(msg.sender == vault(), "Only the valut contract can invoke this function");
        _;
    }

    modifier onlyMasterChef {
        require(msg.sender == address(masterChef()), "Only the master chef contract can invoke this function");
        _;
    }

    modifier syntheticActive() {
        systemStatus().requireSyntheticActive();
        _;
    }

    /* ========== EVENTS ========== */
    event DiscountUpdated(uint newValue);

    event FeeRateUpdated(uint newRate);

    event MinJoinDurationUpdated(uint newValue);

    event FixFeeRateUpdated(uint _newRate);

    event LastOpTimeUpdated(uint _lastOpTime);
}
