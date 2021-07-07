pragma solidity ^0.5.16;

interface ISynthetic {
    //MUTATIVE FUNCTIONS
    function stake(address account, uint amount) external returns (uint);

    function exit(address account, uint amount) external  returns (uint);

    function fix(address account, uint amount, uint maxFee) external returns (uint);

    function exchange(address account, bytes32 sourceKey, uint amount, bytes32 destKey) external returns (uint);

    function chargeWithdrawFee(address account, uint amount) external returns (uint);
}
