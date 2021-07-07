pragma solidity ^0.5.16;

import "../common/Owned.sol";
import "../common/SafeDecimalMath.sol";
import "../common/MixinResolver.sol";
import "../interfaces/ICollateral.sol";
import "../interfaces/ICollateralState.sol";
import "../interfaces/IRewarderState.sol";
import "../interfaces/IRewarder.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/SafeERC20.sol";

contract Rewarder is Owned, MixinResolver, IRewarder {
    using SafeMath for uint;
    using SafeDecimalMath for uint;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    address public tokenAddress;

    uint public startIndex;
    uint public closePeriodDuration = 30 days;
    uint64 public startTime;

    // cache
    uint public totalRewardPeriod;

    uint public periodID;
    mapping(address => uint) public rewardIndex;

    bytes32 private constant CONTRACT_COLLATERAL = "Collateral";
    bytes32 private constant CONTRACT_STATE = "CollateralState";
    bytes32 private constant CONTRACT_REWARDER_STATE = "RewarderState";

    /* ========== CONSTRUCTOR ========== */
    constructor (address _owner, address _resolver, address _tokenAddress) public Owned(_owner) MixinResolver(_resolver) {
        require(_tokenAddress != address(0), "_tokenAddress address cannot be 0");
        tokenAddress = _tokenAddress;
        startTime = uint64(now);
        startIndex = 0;
        periodID = 1;
    }

    function collateral() internal view returns (ICollateral) {
        return ICollateral(resolver.requireAndGetAddress(CONTRACT_COLLATERAL, "Missing Collateral address"));
    }

    function collateralState() internal view returns (ICollateralState) {
        return ICollateralState(resolver.requireAndGetAddress(CONTRACT_STATE, "Missing CollateralState address"));
    }

    function rewarderState() internal view returns (IRewarderState) {
        return IRewarderState(resolver.requireAndGetAddress(CONTRACT_REWARDER_STATE, "Missing RewarderState address"));
    }

    /* ========== SETTERS ============ */
    function setPeriodDuration(uint _period) external onlyOwner {
        closePeriodDuration = _period;
    }

    function setTokenAddress(address _tokenAddress) external onlyOwner {
        require(_tokenAddress != address(0));
        tokenAddress = _tokenAddress;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function closePeriodReward() external onlyOwner {
        require(startTime <= (now - closePeriodDuration), "Too early to close reward period");
        startTime = uint64(now);

        uint periodReward = IERC20(tokenAddress).balanceOf(address(this));
        require(periodReward > 0, "Reward token must greater 0");
        totalRewardPeriod = periodReward;

        uint length = collateralState().debtLedgerLength();
        require(length > 0, "Have no ledger");
        startIndex = length;

        periodID += 1;
    }

    function claimReward() external {
        require(startIndex > 0 && periodID > 1, "System just starts, no reward period closed");

        require(collateral().isRewardClaimable(msg.sender), "Staking ratio is too low to claim reward");

        uint rewardAmount = getUnClaimedReward(msg.sender);
        require(rewardAmount > 0, "No reward currently");

        rewardIndex[msg.sender] = periodID - 1;
        IERC20(tokenAddress).safeTransfer(msg.sender, rewardAmount);
    }

    function getUnClaimedReward(address _account) public view returns (uint) {
        if (startIndex == 0 || periodID == 1) return 0;

        if (rewardIndex[_account] == (periodID - 1)) return 0;

        uint remainderAmount = IERC20(tokenAddress).balanceOf(address(this));
        if (remainderAmount == 0) return 0;

        uint rewardPercent = effectiveDebtRatioForLastCloseIndex(_account, startIndex.sub(1));
        if (rewardPercent == 0) return 0;

        uint rewardAmount = rewardPercent.multiplyDecimal(totalRewardPeriod).preciseDecimalToDecimal();
        if (remainderAmount < rewardAmount) {
            rewardAmount = remainderAmount;
        }
        return rewardAmount;
    }

    function appendAccountDebtData(address account, uint debt, uint debtEntryIndex) external onlyCollateral {
        rewarderState().appendAccountDebtData(
            account,
            debt,
            debtEntryIndex,
            startIndex
        );
    }

    function effectiveDebtRatioForLastCloseIndex(address account, uint closingDebtIndex) internal view returns (uint) {
        (uint debt, ) = rewarderState().applicableDebtData(account, closingDebtIndex);

        if (debt == 0) return 0;

        // internal function will check closingDebtIndex has corresponding debtLedger entry
        return _effectiveDebtRatioForPeriod(closingDebtIndex, debt);
    }

    function _effectiveDebtRatioForPeriod(uint closingDebtIndex, uint debt)
        internal
        view
        returns (uint)
    {
        ICollateralState collateralState = collateralState();
        require(collateralState.debtLedgerLength() >= closingDebtIndex, "No Such DebtLedger");
        uint totalDebt = collateralState.debtLedger(closingDebtIndex);
        uint debtOwnership = debt.divideDecimalRoundPrecise(totalDebt);

        return debtOwnership;
    }

    modifier onlyCollateral {
        require(msg.sender == address(collateral()), "Rewarder: Only collateral contract can perform this action");
        _;
    }
}