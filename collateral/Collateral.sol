pragma solidity ^0.5.16;

import "../common/SafeDecimalMath.sol";
import "../common/Owned.sol";
import "../common/MixinResolver.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IExchangeRates.sol";
import "../interfaces/ISystemStatus.sol";
import "../interfaces/ICollateralState.sol";
import "../interfaces/IRewarder.sol";
import "../interfaces/ICollateral.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/SafeERC20.sol";

contract Collateral is Owned, MixinResolver, ICollateral {
    using SafeMath for uint;
    using SafeDecimalMath for uint;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // Currency key which identifies this Collateral to vault system
    bytes32 public currencyKey;

    // Collateral System Settings
    uint public debtCap;

    uint public targetRatio = SafeDecimalMath.unit() / 5; //actual 500%
    uint public liquidationRatio = SafeDecimalMath.unit() / 2; //actual 200%

    // Liquidation penalty
    uint public liquidationPenalty = 1e18 / 10; //10%
    uint public constant MAX_LIQUIDATION_PENALTY = 1e18 / 5; // Max 20%

    uint public constant MAX_RATIO = 1e18;

    // Max
    uint public constant MAX_MIN_STAKE_DURATION = 1 weeks;

    uint public minStakeDuration = 24 hours; //burn and issue minimum interval

    // feeRate
    uint public feeRate = SafeDecimalMath.unit() / 100; //1%
    uint public constant MAX_FEE_RATE = 1e18 / 5; //20%

    bytes32 public constant eUSD = "eUSD";

    bool private isNative = false;
    //constants
    bytes32 private constant CONTRACT_VAULT = "Vault";
    bytes32 private constant CONTRACT_ACTIONS = "ProxyActions";
    bytes32 private constant CONTRACT_SYSTEM = "SystemStatus";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_STATE = "CollateralState";
    bytes32 private constant CONTRACT_REWARDER = "Rewarder";

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        bytes32 _currencyKey,
        bool _isNative,
        uint _debtCap,
        address _resolver
    )
        public
        Owned(_owner)
        MixinResolver(_resolver)
    {
        //core contracts must be deployed ahead
        require(_debtCap > 0, "_debtCap must greater than 0");

        currencyKey = _currencyKey;
        debtCap = _debtCap;
        isNative = _isNative;
    }

    function vault() internal view returns (IVault) {
        return IVault(resolver.requireAndGetAddress(CONTRACT_VAULT, "Missing Vault address"));
    }

    function exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(resolver.requireAndGetAddress(CONTRACT_EXRATES, "Missing ExchangeRates address"));
    }

    function collateralState() internal view returns (ICollateralState) {
        return ICollateralState(resolver.requireAndGetAddress(CONTRACT_STATE, "Missing CollateralState address"));
    }

    function rewarder() internal view returns (IRewarder) {
        return IRewarder(resolver.requireAndGetAddress(CONTRACT_REWARDER, "Missing Rewarder address"));
    }

    /* ========== SETTERS ============ */
    function setTargetRatio(uint _targetRatio) external onlyOwner {
        require(both(_targetRatio > 0, _targetRatio <= MAX_RATIO), "New target ratio is invalid");
        targetRatio = _targetRatio;
        emit TargetRatioUpdated(_targetRatio);
    }

    function setLiquidationRatio(uint _liquidationRatio) external onlyOwner {
        require(_liquidationRatio <= MAX_RATIO.divideDecimal(SafeDecimalMath.unit().add(liquidationPenalty)), "New liquidation ratio cannot greater than MAX_RATIO / (1 + penalty)");
        require(_liquidationRatio >= targetRatio, "New liquidation ratio cannot less than target ratio");
        liquidationRatio = _liquidationRatio;
        emit LiquidationRatioUpdated(_liquidationRatio);
    }

    function setFeeRate(uint _feeRate) external onlyOwner {
        require(both(_feeRate > 0 ,_feeRate <= MAX_FEE_RATE), "New fee ratio is invalid");
        feeRate = _feeRate;
        emit FeeRateUpdated(_feeRate);
    }

    function setDebtCap(uint _debtCap) external onlyOwner {
        require(_debtCap > 0, "_debtCap must greater than 0");
        debtCap = _debtCap;
        emit DebtCapUpdated(_debtCap);
    }

    function setLiquidationPenalty(uint _penalty) external onlyOwner {
        require(both(_penalty > 0, _penalty <= MAX_LIQUIDATION_PENALTY), "_penalty must greater than 0 and less than 25%");
        liquidationPenalty = _penalty;
        emit LiquidationPenaltyUpdated(_penalty);
    }

    function setMinStakeDuration(uint _duration) external onlyOwner {
        require(_duration <= MAX_MIN_STAKE_DURATION, "stake duration exceed maximum 1 week");
        minStakeDuration = _duration;
        emit MinStakeDurationUpdated(_duration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    //Calls this function transfer amount of collateral to collateralState contract
    function join(address account, uint amount) external onlyCollateralProxy {
        ICollateralState state = collateralState();
        uint newCollateral = state.accountCollateral(account).add(amount);

        state.setCurrentCollateral(account, newCollateral);
        IERC20(collateralState().token()).safeTransferFrom(msg.sender, address(state), amount);
    }

    //Calls this function will mint amount of eUSD and increase debt value, lock amount of collateral according to 
    //target ratio
    function mint(address account, uint amount) external onlyCollateralProxy returns (uint amountToMint, uint feeCharged) {
        (uint index, uint maxMintable, uint existingDebt, , uint totalDebt) = _remainingDebt(account);
        require(totalDebt < debtCap, "Not enought debt to mint, debt cap reached");
        require(amount <= maxMintable, "Amount too large");

        amountToMint = maxMintable < amount ? maxMintable : amount;
        if (index == 0) {
            collateralState().incrementTotalUser();
        }
        feeCharged = amount.multiplyDecimalRound(feeRate);

        _setLastEvent(account);

        _updateDebt(account, existingDebt, amountToMint, totalDebt, true);

        vault().mint(currencyKey, account, amountToMint.sub(feeCharged), feeCharged);
    }

    //Calls this function will burn amount of eUSD from their account and decrease debt value, unlock amount of 
    //collateral according to target ratio
    function burn(address account, uint amount) external onlyCollateralProxy returns (uint debtToBurn, uint feeCharged) {
        require(_canBurn(account), "Min stake time not reached");

        ICollateralState state = collateralState();
        (, uint existingDebt, ) = state.accountDebtData(account);
        feeCharged = amount.multiplyDecimalRound(feeRate);
        debtToBurn = amount.sub(feeCharged);

        require(both(existingDebt >= debtToBurn, debtToBurn > 0), "Not enough debt to burn");

        _updateDebt(account, existingDebt, debtToBurn, state.lastDebtLedgerEntry(), false);

        vault().burn(currencyKey, account, debtToBurn, feeCharged);
    }

    //Calls this function will refund amount of unlocked collateral to the given address
    function exit(address account, address to, uint amount) external onlyCollateralProxy {
        ICollateralState state = collateralState();
        uint unlockAmount = unlockedCollateral(account);
        require(both(unlockAmount >= amount, amount > 0), "Not enough amount to exit");

        uint newCollateral = state.accountCollateral(account).sub(amount);
        state.setCurrentCollateral(account, newCollateral);

        state.transfer(to, amount);
    }

    //Calls this function will burn amount of liquidator's eUSD decrease account's debt. liquidator will 
    //receive extra value of collaterals
    function liquidate(
        address liquidator,
        address account,
        uint amount
    ) external onlyCollateralProxy returns (uint received, uint amountToLiquidate) {
        (bool toLiquidate, bool isFlagged) = _canLiquidate(account);
        require(toLiquidate, "Cannot liquidate user who's collateralisation ratio reaches target ratio");

        if (!isFlagged) {
            collateralState().addToLiquidation(account);
        }

        require(vault().collateral(liquidator) >= amount, "Not enough eUSD to burn");

        ICollateralState state = collateralState();
        uint collateral = state.accountCollateral(account);
        require(collateral > 0, "Not enough collateral to liquidate");

        (uint collateralUSD, uint debt) = _collateralAndDebt(account);
        uint amountToFixRatio = _calAmountToFixRatio(collateralUSD, debt);

        amountToLiquidate = amountToFixRatio < amount ? amountToFixRatio : amount;

        //calculate real collateral received
        uint collateralReceived = exchangeRates().effectiveValue(eUSD, amountToLiquidate, currencyKey);
        received = collateralReceived.multiplyDecimal(SafeDecimalMath.unit().add(liquidationPenalty));

        //collateral received may greater than collateral owned by account in system.
        //Under such circumstance, liquidate all collateral and reduce eUSD to burn
        if (received > collateral) {
            received = collateral;
            amountToLiquidate = exchangeRates().effectiveValue(
                currencyKey,
                collateral.divideDecimal(SafeDecimalMath.unit().add(liquidationPenalty)),
                eUSD
            );
        }

        _updateDebt(account, debt, amountToLiquidate, state.lastDebtLedgerEntry(), false);
        //charges no fee in liquidation
        vault().burn(currencyKey, liquidator, amountToLiquidate, 0);
        state.setCurrentCollateral(account, collateral.sub(received));
        state.transfer(liquidator, received);

        if (amountToLiquidate == amountToFixRatio) {
            collateralState().removeFromLiquidation(account);
        }
    }

    function checkAndRemoveLiquidation(address account) external onlyCollateralProxy {
        ICollateralState state = collateralState();

        require(state.liquidations(account), "Account has no liquidation flag");

        (uint _collateralRatio, , ) = collateralisationRatio(account);
        if (_collateralRatio <= targetRatio) {
            state.removeFromLiquidation(account);
        }
    }

    function _updateDebt(address account, uint existingDebt, uint change, uint totalDebt, bool mint) internal returns (uint newDebt, uint newTotalDebt) {
        if (mint) {
            newDebt = existingDebt.add(change);
            newTotalDebt = totalDebt.add(change);
        } else {
            newDebt = existingDebt.sub(change);
            newTotalDebt = totalDebt.sub(change);
        }

        ICollateralState state = collateralState();
        state.setCurrentDebtData(account, newDebt);
        state.appendDebtLedgerValue(newTotalDebt);

        (, , uint debtEntryIndex) = state.accountDebtData(account);
        rewarder().appendAccountDebtData(account, newDebt, debtEntryIndex);

        //remove liquidation flag if needed
        (uint _collateralRatio, , ) = collateralisationRatio(account);
        bool isFlagged = collateralState().liquidations(account);
        if (both(_collateralRatio <= targetRatio, isFlagged)) {
            collateralState().removeFromLiquidation(account);
        }
    }

    function _setLastEvent(address account) internal {
        collateralState().setLastEvent(account, block.timestamp);
    }

    /* ========== VIEWS ============ */
    //maxDebt returns amount of max mintable debt by total collateral and exchange rates 
    function maxDebt(address account) public view returns (uint) {
        uint value = exchangeRates().effectiveValue(currencyKey, collateralState().accountCollateral(account), eUSD);
        return value.multiplyDecimal(targetRatio);
    }

    function _remainingDebt(address account) internal view returns (uint, uint, uint, uint, uint) {
        ICollateralState state = collateralState();
        //System just started
        (uint index ,uint existingDebt, uint debtEntryIndex) = state.accountDebtData(account);
        uint totalDebt = state.lastDebtLedgerEntry();

        uint maxMintable = maxDebt(account);
        if (existingDebt >= maxMintable) {
            maxMintable = 0;
        } else {
            maxMintable = maxMintable.sub(existingDebt);
        }

        if (debtCap < (totalDebt.add(maxMintable))) {
            maxMintable = debtCap.sub(totalDebt);
        }

        return (index, maxMintable, existingDebt, debtEntryIndex, totalDebt);
    }

    //remainingDebt returns max eUSD mintable by amount of collateral and debt cap
    function remainingDebt(address account)
        external
        view
        returns (
            uint maxMintable,
            uint existingDebt,
            uint totalDebt
        )
    {
        (, maxMintable, existingDebt, , totalDebt) = _remainingDebt(account);
    }

    function collateralAndDebt(address account) public view returns (uint, uint) {
        return _collateralAndDebt(account);
    }

    function _collateralAndDebt(address account) internal view returns (uint, uint) {
        ICollateralState state = collateralState();
        (, uint debt, ) = state.accountDebtData(account);
        uint collateral = state.accountCollateral(account);

        if (collateral == 0) return (0, 0);

        uint collateralUSD = exchangeRates().effectiveValue(currencyKey, collateral, eUSD);
        return (collateralUSD, debt);
    }

    //collateralisationRatio returns account's collateralisation ratio for by debt/value(collateral)
    function collateralisationRatio(address account) public view returns (uint, uint, uint) {
        (uint collateralUSD, uint debt) = _collateralAndDebt(account);

        if (collateralUSD == 0) return (0, 0, 0);

        return (debt.divideDecimalRound(collateralUSD), collateralUSD, debt);
    }

    //collateralisationRatio returns account(index) collateralisation ratio by debt/value(collateral)
    function collateralisationRatioIndex(uint index) external view returns (uint, uint, uint) {
        ICollateralState state = collateralState();
        require(both(index > 0, index <= state.totalUser()), "Index has not been set");

        address account = state.userIndexer(index);
        return collateralisationRatio(state.userIndexer(index));
    }

    //check if account's collateralisation ratio is below liquidationRatio
    function canLiquidate(address account) public view returns (bool) {
        (bool toLiquidate, ) = _canLiquidate(account);
        return toLiquidate;
    }

    function _canLiquidate(address account) internal view returns (bool, bool) {
        (uint _collateralRatio, , ) = collateralisationRatio(account);
        if (_collateralRatio <= targetRatio) {
            return (false, false);
        } 

        bool isFlagged = collateralState().liquidations(account);
        return (either(_collateralRatio >= liquidationRatio, isFlagged), isFlagged);
    }

    //check if account's collateralisation ratio is below targetRatio
    function isRewardClaimable(address account) external view returns (bool) {
        (uint _collateralRatio, , ) = collateralisationRatio(account);
        return _collateralRatio <= targetRatio;
    }

    //calculate unlocked collateral
    function unlockedCollateral(address account) public view returns (uint) {
        ICollateralState state = collateralState();
        (, uint debt, ) = state.accountDebtData(account);
        uint collateral = state.accountCollateral(account);
        if (collateral == 0) return 0;

        uint amountLocked = exchangeRates().effectiveValue(eUSD, debt, currencyKey).divideDecimalRound(targetRatio);

        if (amountLocked >= collateral) return 0;
        return collateral.sub(amountLocked);
    }

    //calculate amount to fix collateralisation ratio to target ratio
    function calAmountToFixRatio(address account) public view returns (uint) {
        (bool toLiquidate, bool isFlagged) = _canLiquidate(account);
        if (!toLiquidate) {
            return 0;
        }

        (uint collateralUSD, uint debt) = _collateralAndDebt(account);
        return _calAmountToFixRatio(collateralUSD, debt);
    }

    function _calAmountToFixRatio(uint collateral, uint debt) internal view returns (uint) {
        uint dividend = debt.sub(collateral.multiplyDecimal(targetRatio));
        uint divisor = SafeDecimalMath.unit().sub(SafeDecimalMath.unit().add(liquidationPenalty).multiplyDecimal(targetRatio));

        return dividend.divideDecimal(divisor);
    }

    function collateralStateAddress() external view returns (address) {
        return resolver.requireAndGetAddress(CONTRACT_STATE, "Missing CollateralState address");
    }

    function tokenAddress() external view returns (address) {
        return collateralState().token();
    }

    function nativeCollateral() external view returns (bool) {
        return isNative;
    }

     function rewarderAddress() external view returns (address) {
        return resolver.requireAndGetAddress(CONTRACT_REWARDER, "Missing Rewarder address");
    }

    function _canBurn(address account) internal view returns (bool) {
        return now >= _lastEvent(account).add(minStakeDuration);
    }

    function _lastEvent(address account) internal view returns (uint) {
        return collateralState().lastEvent(account);
    }

    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    /* ========== MODIFIERS ========== */
    modifier onlyCollateralProxy {
        require(msg.sender == resolver.requireAndGetAddress(CONTRACT_ACTIONS, "Missing ProxyActions address"), "Only the proxy contract can invoke this function");
        _;
    }

    /* ========== EVENTS ========== */
    event TargetRatioUpdated(uint newRatio);

    event LiquidationRatioUpdated(uint newRatio);

    event FeeRateUpdated(uint newRate);

    event DebtCapUpdated(uint newValue);

    event LiquidationPenaltyUpdated(uint newValue);

    event MinStakeDurationUpdated(uint newValue);
}
