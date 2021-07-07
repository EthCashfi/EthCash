pragma solidity ^0.5.16;


/**
 * @title Collateral Interface
 * @notice Abstract contract to hold public getters
 */
interface ICollateral {
    //mutative functions
    function join(address account, uint amount) external;

    function mint(address account, uint amount) external returns (uint amountToMint, uint feeCharged);

    function burn(address account, uint amount) external returns (uint debtToBurn, uint feeCharged);

    function exit(address account, address to, uint amount) external;

    function liquidate(
        address liquidator,
        address account,
        uint amount
    ) external returns (uint received, uint amountToLiquidate);

    function checkAndRemoveLiquidation(address account) external;

    //views
    function isRewardClaimable(address account) external view returns (bool);

    function tokenAddress() external view returns (address);

    function nativeCollateral() external view returns (bool);
}
