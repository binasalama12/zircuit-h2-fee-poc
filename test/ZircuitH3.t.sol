// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";

interface IERC20V {
    function balanceOf(address) external view returns (uint256);
}

interface IVaultComposer {
    function lzCompose(
        address composeSender,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

/// @notice H3 behavioral probe on Base fork: VaultComposer.lzCompose failure semantics.
/// Compose message format (OFTComposeMsgCodec, verified from deployed source):
/// [nonce u64][srcEid u32][amountLD u256][composeFrom bytes32][composeMsg]  (76-byte header)
contract ZircuitH3Test is Test {
    address constant VAULT = 0x03067bbD0d41E3Fe4A0bb6ca67c99e7352Da4CAE;
    address constant COMPOSER = 0xBb801ED781dF31F660cC743bEf7Bb9D04B030923;
    bytes32 constant SYNC_STORAGE = 0x0547bf30cac86716723f9098631557b8ec4ea137f23c7b6b7b154c7fd6947600;

    uint32 constant ETH_EID = 30101;
    address endpoint;
    address user = address(0xB0B5);

    function setUp() public {
        vm.createSelectFork("base");
        endpoint = address(uint160(uint256(vm.load(COMPOSER, bytes32(uint256(SYNC_STORAGE) + 3)))));
        console.log("composer endpoint:", endpoint);
        console.log("composer vault-share balance before deal:", IERC20V(VAULT).balanceOf(COMPOSER));
        deal(VAULT, COMPOSER, 50_000e6);
        console.log("composer vault-share balance after deal:", IERC20V(VAULT).balanceOf(COMPOSER));
        vm.deal(endpoint, 2 ether);
    }

    function _composeMessage(uint256 amountLD, bytes memory composeMsg) internal view returns (bytes memory) {
        return abi.encodePacked(uint64(1), ETH_EID, amountLD, bytes32(uint256(uint160(user))), composeMsg);
    }

    function _failingRedeemComposeMsg(uint256 minMsgValue) internal pure returns (bytes memory) {
        SendParam memory sp;
        sp.dstEid = ETH_EID;
        sp.to = bytes32(uint256(uint160(address(0xBEEF))));
        sp.amountLD = 0; // overwritten by composer with redeemed amount
        sp.minAmountLD = type(uint256).max; // forces SlippageExceeded inside handleCompose
        sp.extraOptions = new bytes(0);
        sp.composeMsg = new bytes(0);
        sp.oftCmd = new bytes(0);
        return abi.encode(sp, minMsgValue);
    }

    // (b) minMsgValue not met -> lzCompose re-reverts with InsufficientMsgValue (retryable, NOT refunded)
    function testH3_InsufficientMsgValueRevertsForRetry() public {
        bytes memory msg_ = _composeMessage(10_000e6, _failingRedeemComposeMsg(1 ether));
        uint256 balBefore = IERC20V(VAULT).balanceOf(COMPOSER);
        vm.prank(endpoint);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("InsufficientMsgValue(uint256,uint256)")), 1 ether, 0)
        );
        IVaultComposer(COMPOSER).lzCompose{ value: 0 }(VAULT, bytes32(uint256(1)), msg_, address(0), new bytes(0));
        assertEq(IERC20V(VAULT).balanceOf(COMPOSER), balBefore, "state changed on InsufficientMsgValue path");
        console.log("H3(b): InsufficientMsgValue -> full revert, composer balance unchanged (retryable)");
    }

    // (a) compose fails (slippage) + refund underfunded (msg.value = 0) -> whole lzCompose reverts, no half-state
    function testH3_FailedComposeUnderfundedRefundRevertsAtomically() public {
        bytes memory msg_ = _composeMessage(10_000e6, _failingRedeemComposeMsg(0));
        uint256 balBefore = IERC20V(VAULT).balanceOf(COMPOSER);
        vm.prank(endpoint);
        vm.expectRevert();
        IVaultComposer(COMPOSER).lzCompose{ value: 0 }(VAULT, bytes32(uint256(2)), msg_, address(0), new bytes(0));
        assertEq(IERC20V(VAULT).balanceOf(COMPOSER), balBefore, "composer balance changed despite revert");
        console.log("H3(a): failed compose + underfunded refund -> lzCompose reverted atomically, shares intact at composer");
    }

    // (c) compose fails (slippage) + refund funded -> refund send succeeds: shares leave composer toward composeFrom (user) on src chain
    function testH3_FailedComposeFundedRefundSucceeds() public {
        bytes memory msg_ = _composeMessage(10_000e6, _failingRedeemComposeMsg(0));
        uint256 balBefore = IERC20V(VAULT).balanceOf(COMPOSER);
        vm.prank(endpoint);
        IVaultComposer(COMPOSER).lzCompose{ value: 0.2 ether }(
            VAULT,
            bytes32(uint256(3)),
            msg_,
            address(0),
            new bytes(0)
        );
        uint256 balAfter = IERC20V(VAULT).balanceOf(COMPOSER);
        console.log("H3(c): composer share balance before:", balBefore);
        console.log("H3(c): composer share balance after refund:", balAfter);
        assertEq(balBefore - balAfter, 10_000e6, "refund did not dispatch exactly the composed amount");
        console.log("H3(c): funded refund dispatched 10000e6 shares back toward composeFrom (user) on srcEid");
    }
}
