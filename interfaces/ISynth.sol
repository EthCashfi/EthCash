pragma solidity ^0.5.16;


interface ISynth {
    function currencyKey() external view returns (bytes32);

    function burn(address account, uint amount) external;

    function issue(address account, uint amount) external;

    function transfer(address to, uint value) external returns (bool);

    function transferFrom(address from, address to, uint value) external returns (bool);
}
