pragma solidity ^0.5.16;

interface IExchanger {
    //MUTATIVE FUNCTIONS
    function exchange(address from, bytes32 sourceKey, uint amount, bytes32 destKey) external returns (uint);

    //VIEWS
    function canFix() external view returns (bool);

    function maxAmountToFix() external view returns (uint);

    function calAmountFromBlackhole(uint amount) external view returns (uint, bool);

    function calAmountToBlackhole(uint amount) external view returns (uint, bool);

    function currentFeeRate() external view returns (uint, bool);

    function currentBalanceFactor() external view returns (uint);

    function totalIssuedSynthsAndLP() external returns (uint);

    function totalIssuedSynths() external view returns (uint);
}
