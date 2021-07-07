pragma solidity ^0.5.16;

import "../common/Owned.sol";
import "../common/SafeDecimalMath.sol";
import "../common/State.sol";
import "../interfaces/ICollateralState.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/SafeERC20.sol";


contract CollateralState is Owned, State, ICollateralState {
    using SafeMath for uint;
    using SafeDecimalMath for uint;
    using SafeERC20 for IERC20;

    //User Last Event records user's last issurance event timestamp
    mapping(address => uint) internal userLastEvent;

    // A struct for handing values(collateral and debt) associated
    // with an individual user's debt position
    // Debt position store global debt value
    struct DebtData {
        uint index;
        uint debt;
        uint debtEntryIndex;
    }

    mapping(address => DebtData) public accountDebtData;
    mapping(address => uint) public accountCollateral;

    mapping(uint => address) public userIndexer;

    mapping(address => bool) public liquidations;

    // Amount of accounts who use collateral to build eUSD
    uint public totalUser;

    // Global debt pool tracking
    uint[] public debtLedger;

    // Associated ERC20 address
    address public token;

    constructor(address _owner, address _associatedContract, address _token) public Owned(_owner) State(_associatedContract) {
        require(_token != address(0), "_token can not be zero");
        token = _token;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function setAssociatedERC20(address _token) external onlyOwner {
        require(_token != address(0), "_token can not be zero");
        token = _token;
    }

    function setLastEvent(address user, uint timestamp) external onlyAssociatedContract {
        userLastEvent[user] = timestamp;
    }

    function setCurrentCollateral(address account, uint collateral) external onlyAssociatedContract {
        accountCollateral[account] = collateral;
    }

    function setCurrentDebtData(address account, uint debt) external onlyAssociatedContract {
        if (accountDebtData[account].index == 0) {
            accountDebtData[account].index = totalUser;
            userIndexer[totalUser] = account;
        }
        accountDebtData[account].debt = debt;
        accountDebtData[account].debtEntryIndex = debtLedger.length;
    }

    function incrementTotalUser() external onlyAssociatedContract {
        totalUser = totalUser.add(1);
    }

    function appendDebtLedgerValue(uint value) external onlyAssociatedContract {
        debtLedger.push(value);
    }

    function addToLiquidation(address account) external onlyAssociatedContract {
       liquidations[account] = true;
    }

    function removeFromLiquidation(address account) external onlyAssociatedContract {
       delete liquidations[account];
    }

    /* ========== VIEWS ========== */
    function debtLedgerLength() external view returns (uint) {
        return debtLedger.length;
    }

    function lastEvent(address user) external view returns (uint) {
        return userLastEvent[user];
    }

    function lastDebtLedgerEntry() external view returns (uint) {
        if (debtLedger.length == 0) return 0;
        return debtLedger[debtLedger.length - 1];
    }

    function hasCollateral(address account) external view returns (bool) {
        return accountCollateral[account] > 0;
    }

    function hasDebt(address account) external view returns (bool) {
        return accountDebtData[account].debt > 0;
    }

    function transfer(address to, uint amount) external onlyAssociatedContract returns (bool) {
        IERC20(token).safeTransfer(to, amount);
        return true;
    }
}
