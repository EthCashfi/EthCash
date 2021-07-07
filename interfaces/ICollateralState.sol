pragma solidity ^0.5.16;

interface ICollateralState {
    //views
    function debtLedgerLength() external view returns (uint);

    function hasCollateral(address account) external view returns (bool);

    function hasDebt(address account) external view returns (bool);

    function lastDebtLedgerEntry() external view returns (uint);

    function lastEvent(address user) external view returns (uint);

    //mutative functions

    function incrementTotalUser() external;

    function setCurrentDebtData(address account, uint debt) external;

    function setCurrentCollateral(address account, uint collateral) external;

    function appendDebtLedgerValue(uint value) external;

    function setLastEvent(address user, uint timestamp) external;

    function transfer(address to, uint amount) external returns (bool);

    function addToLiquidation(address account) external;

    function removeFromLiquidation(address account) external;

    //views

    function accountCollateral(address account) external view returns (uint);

    function accountDebtData(address account) external view returns (uint, uint, uint);

    function userIndexer(uint index) external view returns (address);

    function liquidations(address account) external view returns (bool);

    function token() external view returns (address);

    function totalUser() external view returns (uint);

    function debtLedger(uint index) external view returns (uint);
}
