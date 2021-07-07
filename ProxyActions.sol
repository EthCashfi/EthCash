pragma solidity ^0.5.16;

// Inheritance
import "./common/Owned.sol";
import "./common/MixinResolver.sol";
import "./common/Proxyable.sol";

// Internal references
import "./interfaces/INative.sol";
import "./interfaces/ICollateral.sol";
import "./interfaces/ISystemStatus.sol";
import "./interfaces/IERC20Unsafe.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/SafeERC20.sol";

contract ProxyActions is Owned, Proxyable, MixinResolver {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */
    bytes32 private constant CONTRACT_SYSTEM = "SystemStatus";
    address payable private nativeAddress;

    /* ========== CONSTRUCTOR ========== */
    constructor(
        address payable _proxy,
        address _owner,
        address _resolver,
        address payable _nativeAddress
    )
    public
    Owned(_owner)
    Proxyable(_proxy)
    MixinResolver(_resolver)
    {
        require(_nativeAddress != address(0), "_nativeAddress cannot be 0");
        nativeAddress = _nativeAddress;
    }

    function() external payable {
        require(msg.sender == nativeAddress); // only accept Native token via fallback from the Native contract
    }

    function systemStatus() internal view returns (ISystemStatus) {
        return ISystemStatus(resolver.requireAndGetAddress(CONTRACT_SYSTEM, "Missing SystemStatus address"));
    }

    function collateral(bytes32 currencyKey) internal view returns (ICollateral) {
        return ICollateral(resolver.requireAndGetAddress(currencyKey, "Missing Collateral address"));
    }

    /* ========== SETTERS ============ */

    /* ========== MUTATIVE FUNCTIONS ========== */
    //User calls this need to approve this proxy contract first, then will automatically transfer the given amount to 
    //collateral state contract.
    function join(bytes32 currencyKey, uint amount, bool standard) external optionalProxy collateralActive(currencyKey) {
        require(amount > 0, "Amount can not be zero");

        // Gets token from the user's wallet
        ICollateral iCollateral = collateral(currencyKey);
        require(!iCollateral.nativeCollateral(), "ERC20 collateral only");

        // Approves Collateral to take the token amount
        if (standard) {
            IERC20 tokenAddress = IERC20(iCollateral.tokenAddress());
            tokenAddress.safeTransferFrom(messageSender, address(this), amount);
            tokenAddress.safeApprove(address(iCollateral), amount);
        } else {
            IERC20Unsafe tokenAddress = IERC20Unsafe(iCollateral.tokenAddress());
            require(tokenAddress.transferFrom(messageSender, address(this), amount), "transferFrom failed");
            uint fromAmount = tokenAddress.allowance(messageSender, address(iCollateral));
            require(tokenAddress.approve(address(iCollateral), fromAmount, amount), "approve failed");
        }

        iCollateral.join(messageSender, amount);
        emitJoined(messageSender, amount);
    }

    //User calls this will automatically return amount(not greater than unlocked amount) of collateral from
    //state contract.
    function exit(bytes32 currencyKey, uint amount) external optionalProxy collateralActive(currencyKey) {
        require(amount > 0, "Amount can not be zero");

        ICollateral iCollateral = collateral(currencyKey);
        require(!iCollateral.nativeCollateral(), "ERC20 collateral only");

        iCollateral.exit(messageSender, messageSender, amount);
        emitExited(messageSender, amount);
    }

    //User mints eUSD by this function and increase the given collateral debt.
    function mint(bytes32 currencyKey, uint debtAmount) external optionalProxy collateralActive(currencyKey) {
        require(debtAmount > 0, "Amount can not be zero");

        (uint amountToMint, uint feeCharged) = collateral(currencyKey).mint(messageSender, debtAmount);
        emitMinted(messageSender, amountToMint, feeCharged);
    }

    //User burns eUSD by this function and decrease the given collateral debt.
    function burn(bytes32 currencyKey, uint debtAmount) external optionalProxy collateralActive(currencyKey) {
        require(debtAmount > 0, "Amount can not be zero");

        (uint debtToBurn, uint feeCharged) = collateral(currencyKey).burn(messageSender, debtAmount);
        emitBurned(messageSender, debtToBurn, feeCharged);
    }

    //User calls this will liquidate the given account, burn his eUSD and receive amount of collateral
    function liquidate(bytes32 currencyKey, address account, uint amount) external optionalProxy collateralActive(currencyKey) {
        require(amount > 0, "Amount can not be zero");

        (uint received, uint amountToLiquidate) = collateral(currencyKey).liquidate(messageSender, account, amount);
        emitLiquidated(messageSender, account, received, amountToLiquidate);
    }

    function checkAndRemoveLiquidation(bytes32 currencyKey) external optionalProxy collateralActive(currencyKey) {
        collateral(currencyKey).checkAndRemoveLiquidation(messageSender);

        emitAccountRemovedFromLiquidation(messageSender);
    }

    //Join native only supports native token
    function joinNative(bytes32 currencyKey) external payable optionalProxy collateralActive(currencyKey) {
        require(msg.value > 0, "msg.value can not be zero");

        ICollateral iCollateral = collateral(currencyKey);
        require(iCollateral.nativeCollateral(), "Native collateral only");

        //transfer native token to native contract
        (bool success, ) = nativeAddress.call.value(msg.value)(abi.encodeWithSignature("deposit()"));
        require(success, "Transfer native failed");

        // Approves Collateral to take the token amount
        IERC20(nativeAddress).safeApprove(address(iCollateral), msg.value);

        iCollateral.join(messageSender, msg.value);
        emitJoined(messageSender, msg.value);
    }

    //Exit native only supports native token
    function exitNative(bytes32 currencyKey, uint amount) external optionalProxy collateralActive(currencyKey) {
        require(amount > 0, "Amount can not be zero");

        ICollateral iCollateral = collateral(currencyKey);
        require(iCollateral.nativeCollateral(), "Native collateral only");

        iCollateral.exit(messageSender, address(this), amount);
        emitExited(messageSender, amount);

        INative(nativeAddress).withdraw(amount);
         _internalSafeTransfer(messageSender, amount);
    }

    function _internalSafeTransfer(address payable to, uint256 value) internal {
        (bool success, ) = to.call.value(value)("");
        require(success, "Transfer native failed");
    }

    /* ========== VIEWS ============ */
    function collateralAddress(bytes32 currencyKey) external view returns(address) {
        return address(collateral(currencyKey));
    }

    function tokenAddress(bytes32 currencyKey) external view returns (address) {
        return collateral(currencyKey).tokenAddress();
    }

    /* ========== MODIFIERS =(========= */
    //Mutative functions can be called only when the given collateral and system are both active.
    modifier collateralActive(bytes32 currencyKey) {
        systemStatus().requireCollateralActive(currencyKey);
        _;
    }

    /* ========== EVENTS ========== */
    function addressToBytes32(address input) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(input)));
    }

    event Joined(address indexed account, uint amount);
    bytes32 internal constant JOINED_SIG = keccak256("Joined(address,uint256)");

    function emitJoined(address account, uint amount) internal {
        proxy._emit(abi.encode(amount), 2, JOINED_SIG, addressToBytes32(account), 0, 0);
    }

    event Exited(address indexed account, uint amount);
    bytes32 internal constant EXITED_SIG = keccak256("Exited(address,uint256)");

    function emitExited(address account, uint amount) internal {
        proxy._emit(abi.encode(amount), 2, EXITED_SIG, addressToBytes32(account), 0, 0);
    }

    event Minted(address indexed account, uint amount);
    bytes32 internal constant MINTED_SIG = keccak256("Minted(address,uint256)");

    function emitMinted(address account, uint amount, uint fee) internal {
        proxy._emit(abi.encode(amount, fee), 2, MINTED_SIG, addressToBytes32(account), 0, 0);
    }

    event Burned(address indexed account, uint amount, uint fee);
    bytes32 internal constant BURNED_SIG = keccak256("Burned(address,uint256,uint256)");

    function emitBurned(address account, uint amount, uint fee) internal {
        proxy._emit(abi.encode(amount, fee), 2, BURNED_SIG, addressToBytes32(account), 0, 0);
    }

    event Liquidated(address indexed liquidator, address indexed account, uint received, uint amountToLiquidate);
    bytes32 internal constant LIQUIDATED_SIG = keccak256("Liquidated(address,address,uint256,uint256)");

    function emitLiquidated(address liquidator, address account, uint received, uint amountToLiquidate) internal {
        proxy._emit(abi.encode(received, amountToLiquidate), 3, LIQUIDATED_SIG, addressToBytes32(liquidator), addressToBytes32(account), 0);
    }

    event AccountRemovedFromLiquidation(address account);
    bytes32 internal constant REMOVED_SIG = keccak256("AccountRemovedFromLiquidation(address)");

    function emitAccountRemovedFromLiquidation(address account) internal {
        proxy._emit(abi.encode(account), 1, REMOVED_SIG, 0, 0, 0);
    }
}
