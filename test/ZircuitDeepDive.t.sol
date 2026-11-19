// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";
import { MockStrategy4626 } from "../src/MockStrategy.sol";

// ---- LayerZero OFT types (ABI mirrors) ----
struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}
struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}
struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}
struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}
struct DeltaMessage {
    bool mint;
    uint64 delta;
}
struct ComposerEntry {
    address initiator;
    uint256 shareAmount;
    SendParam sendParam;
    uint256 fee;
    uint256 txFee;
    address refundAddress;
    bool fulfilled;
    bool canceled;
}
struct VTEntry {
    address initiator;
    SendParam sendParam;
    MessagingFee fee;
    address refundAddress;
    uint256 txFee;
    bool fulfilled;
    bool canceled;
    bool signedQuote;
    MessagingReceipt msgReceipt;
    OFTReceipt oftReceipt;
}

interface IERC20D {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

interface IVaultD {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function deposit(uint256, address) external returns (uint256);
    function mint(uint256, address) external returns (uint256);
    function withdraw(uint256, address, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function approve(address, uint256) external returns (bool);
    function previewRedeem(uint256) external view returns (uint256);
}

interface IUOFTD {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function mint(uint256) external;
    function mintTo(address, uint256) external;
    function burn(uint256) external;
    function deposit(uint256) external;
    function withdraw(uint256) external;
}

interface IComposerD {
    function redeemAndSend(uint256, SendParam memory, address) external payable;
    function cancelWithdrawal(uint256) external;
    function processWithdrawals(uint256[] calldata, uint256[] calldata) external payable;
    function getWithdrawalQueueLength() external view returns (uint256);
    function getWithdrawalQueueEntry(uint256) external view returns (ComposerEntry memory);
}

interface ISMDeep {
    function allowStrategy(address, bool) external;
    function deployFunds(address, uint256, uint256) external returns (uint256);
    function freeFunds(address, uint256, uint256) external returns (uint256);
    function reportDelta(address) external payable;
    function getUnderlyingByStrategy(address) external view returns (int256);
    function hasRole(bytes32, address) external view returns (bool);
}

interface IARDeep {
    function updateAccountingLocal(DeltaMessage calldata) external;
}

interface IVaultTokenD {
    function send(SendParam calldata, MessagingFee calldata, address)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory);
    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory);
    function cancelWithdrawal(uint256) external;
    function getWithdrawalQueueLength() external view returns (uint256);
    function getWithdrawalQueueEntry(uint256) external view returns (VTEntry memory);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IAdapterD {
    function send(SendParam calldata, MessagingFee calldata, address)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory);
    function send(SendParam calldata, MessagingFee calldata, address, uint256, uint256, bytes calldata)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory);
    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory);
}

/// @notice Deep-dive fork validation, Base hub. Areas 1, 2, 4 + AR burn path.
contract ZircuitDeepDiveBaseTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SM = 0xf7E745658fa6f1fe8f2CAb47861a273991Cd3374;
    address constant AR = 0x7fCeB53b2959861D29057361158a2B41cAAffD68;
    address constant VAULT = 0x03067bbD0d41E3Fe4A0bb6ca67c99e7352Da4CAE;
    address constant UOFT = 0xd7aBC360dfcF1B6dD0a03138235e12A2bc1c1C8B;
    address constant COMPOSER = 0xBb801ED781dF31F660cC743bEf7Bb9D04B030923;
    uint32 constant LOCAL_EID = 30184;

    bytes32 constant ROLE_ALLOC = keccak256("ALLOCATION_MANAGER");
    bytes32 constant ROLE_REPORT = keccak256("REPORTING_MANAGER");
    bytes32 constant ROLE_STRATEGY = keccak256("STRATEGY_MANAGER");
    bytes32 constant ROLE_WD = keccak256("WITHDRAWAL_MANAGER");

    address allocator = address(0xA110C);
    address reporter = address(0x8E907);
    address stratAdmin = address(0x57A7E);
    address keeper = address(0xCE99);

    MockStrategy4626 mock;

    function _grantRole(address target, bytes32 role, address account) internal {
        bytes32 base = keccak256(
            abi.encode(uint256(keccak256("openzeppelin.storage.AccessControl")) - 1)
        ) & ~bytes32(uint256(0xff));
        bytes32 roleDataSlot = keccak256(abi.encode(role, base));
        bytes32 memberSlot = keccak256(abi.encode(account, roleDataSlot));
        vm.store(target, memberSlot, bytes32(uint256(1)));
    }

    function setUp() public {
        vm.createSelectFork("base");
        _grantRole(SM, ROLE_ALLOC, allocator);
        _grantRole(SM, ROLE_REPORT, reporter);
        _grantRole(SM, ROLE_STRATEGY, stratAdmin);
        _grantRole(COMPOSER, ROLE_WD, keeper);
        deal(USDC, SM, 5_000_000e6);
        mock = new MockStrategy4626(USDC);
        vm.prank(stratAdmin);
        ISMDeep(SM).allowStrategy(address(mock), true);
    }

    function pps() internal view returns (uint256) {
        return (IVaultD(VAULT).totalAssets() * 1e18) / IVaultD(VAULT).totalSupply();
    }

    // ---------- D1a: donation moves PPS (balance-based totalAssets); extraction at live scale ----------
    function testD1_DonationPPS_And_ExtractionBound() public {
        address attacker = address(0xA77AC);
        address victim = address(0xB1C71);

        // attacker buys in: 100k zUSDC deposited via composer -> shares
        deal(UOFT, COMPOSER, 400_000e6);
        vm.prank(COMPOSER);
        uint256 atkShares = IVaultD(VAULT).deposit(100_000e6, attacker);
        console.log("D1 attacker shares for 100k:", atkShares);

        uint256 pps0 = pps();
        console.log("D1 PPS before donation x1e18:", pps0);

        // donation: attacker transfers 100k zUSDC straight to the Vault
        deal(UOFT, attacker, 100_000e6);
        vm.prank(attacker);
        IUOFTD(UOFT).transfer(VAULT, 100_000e6);
        uint256 pps1 = pps();
        console.log("D1 PPS after 100k donation x1e18:", pps1);
        assertGt(pps1, pps0, "donation did not move PPS");

        // victim deposits 100k at the inflated PPS
        vm.prank(COMPOSER);
        uint256 vicShares = IVaultD(VAULT).deposit(100_000e6, victim);
        console.log("D1 victim shares for 100k at inflated PPS:", vicShares);
        assertLt(vicShares, atkShares, "victim not diluted by donation");

        // attacker exits fully
        vm.prank(attacker);
        IVaultD(VAULT).approve(COMPOSER, type(uint256).max);
        vm.prank(COMPOSER);
        uint256 out = IVaultD(VAULT).redeem(atkShares, attacker, attacker);
        console.log("D1 attacker zUSDC out:", out);
        console.log("D1 attacker total in: 200000e6 (100k deposit + 100k donation)");
        console.log("D1 attacker net (out - in):", int256(out) - int256(200_000e6));
        assertLt(out, 200_000e6, "donation attack PROFITABLE at live scale");
    }

    // ---------- D1b: ERC4626 round-trip rounding never favors the user ----------
    function testD1_RoundingRoundTrip() public {
        address user = address(0x05E2);
        uint256 x = 1_000_003; // odd wei-level amount
        deal(UOFT, COMPOSER, 10_000_000);
        vm.prank(COMPOSER);
        uint256 shares = IVaultD(VAULT).deposit(x, user);
        vm.prank(user);
        IVaultD(VAULT).approve(COMPOSER, type(uint256).max);
        vm.prank(COMPOSER);
        uint256 out = IVaultD(VAULT).redeem(shares, user, user);
        console.log("D1 roundtrip in:", x);
        console.log("D1 roundtrip shares:", shares, "out:", out);
        assertLe(out, x, "rounding favored the user");
    }

    // ---------- D1c: Vault / UnderlyingOFT access gates hold for random users ----------
    function testD1_AccessGates() public {
        address rando = address(0xBA0);
        vm.startPrank(rando);
        vm.expectRevert();
        IVaultD(VAULT).deposit(1, rando);
        vm.expectRevert();
        IVaultD(VAULT).mint(1, rando);
        vm.expectRevert();
        IVaultD(VAULT).withdraw(1, rando, rando);
        vm.expectRevert();
        IVaultD(VAULT).redeem(1, rando, rando);
        vm.expectRevert();
        IUOFTD(UOFT).mint(1);
        vm.expectRevert();
        IUOFTD(UOFT).mintTo(rando, 1);
        vm.expectRevert();
        IUOFTD(UOFT).burn(1);
        vm.expectRevert();
        IUOFTD(UOFT).deposit(1);
        vm.expectRevert();
        IUOFTD(UOFT).withdraw(1);
        vm.stopPrank();
        console.log("D1 all access gates reverted for random caller");
    }

    // ---------- D2c: allowStrategy(false) ignores residual basis -> loss never reaches the hub ----------
    function testD2_RemoveStrategyResidualBasis() public {
        address m = address(mock);
        vm.prank(allocator);
        ISMDeep(SM).deployFunds(m, 100_000e6, 0);
        assertEq(ISMDeep(SM).getUnderlyingByStrategy(m), int256(100_000e6));

        mock.slash(50_000e6); // strategy loses half its value
        uint256 shares = MockStrategy4626(m).balanceOf(SM);
        vm.prank(allocator);
        uint256 received = ISMDeep(SM).freeFunds(m, shares, 0);
        console.log("D2 freed (expect 50000e6):", received);
        int256 basis = ISMDeep(SM).getUnderlyingByStrategy(m);
        console.log("D2 residual basis after free-all (expect +50000e6):", basis);
        assertEq(basis, int256(50_000e6));
        assertEq(MockStrategy4626(m).balanceOf(SM), 0);

        uint256 assetsBefore = IVaultD(VAULT).totalAssets();
        // removal succeeds even though basis != 0 and the -50k delta was never reported
        vm.prank(stratAdmin);
        ISMDeep(SM).allowStrategy(m, false);
        console.log("D2 strategy removed with residual basis +50k, no basis check fired");

        // the correcting report can no longer be made for this strategy
        vm.prank(reporter);
        vm.expectRevert();
        ISMDeep(SM).reportDelta(m);
        assertEq(IVaultD(VAULT).totalAssets(), assetsBefore, "hub assets changed");
        console.log("D2 hub never burns the 50k loss: PPS permanently overstated unless strategy re-added + reported");
    }

    // ---------- D2b: repeated reportDelta is a no-op once basis advanced (no double-apply) ----------
    function testD2_DoubleReportNoOp() public {
        address m = address(mock);
        vm.prank(allocator);
        ISMDeep(SM).deployFunds(m, 100_000e6, 0);
        deal(USDC, m, IERC20D(USDC).balanceOf(m) + 10_000e6);
        uint256 a0 = IVaultD(VAULT).totalAssets();
        vm.prank(reporter);
        ISMDeep(SM).reportDelta(m);
        uint256 a1 = IVaultD(VAULT).totalAssets();
        console.log("D2 first report dAssets (expect +10000e6):", int256(a1) - int256(a0));
        assertEq(a1 - a0, 10_000e6);
        vm.prank(reporter);
        ISMDeep(SM).reportDelta(m);
        uint256 a2 = IVaultD(VAULT).totalAssets();
        console.log("D2 second report dAssets (expect 0):", int256(a2) - int256(a1));
        assertEq(a2, a1, "second report re-applied the delta");
    }

    // ---------- D2/D3: AR burn larger than Vault balance reverts atomically ----------
    function testD2_BurnOverdrawReverts() public {
        uint256 bal = IUOFTD(UOFT).balanceOf(VAULT);
        DeltaMessage memory msg_ = DeltaMessage({ mint: false, delta: uint64(bal + 1_000_000e6) });
        vm.prank(SM);
        vm.expectRevert();
        IARDeep(AR).updateAccountingLocal(msg_);
        console.log("D2 burn overdraw reverted atomically; vault zUSDC balance:", bal);
    }

    // ---------- D4: VaultComposer queue — duplicate-id batch DoS, canceled-skip (Zenith L-10 fix), minAmountLD self-brick + cancel escape ----------
    function _enqueueLocal(address user, uint256 shareAmount, uint256 minAmountLD)
        internal
        returns (uint256 id)
    {
        deal(VAULT, user, shareAmount);
        vm.prank(user);
        IVaultD(VAULT).approve(COMPOSER, shareAmount);
        SendParam memory sp = SendParam({
            dstEid: LOCAL_EID,
            to: bytes32(uint256(uint160(user))),
            amountLD: shareAmount,
            minAmountLD: minAmountLD,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        vm.prank(user);
        IComposerD(COMPOSER).redeemAndSend(shareAmount, sp, user);
        id = IComposerD(COMPOSER).getWithdrawalQueueLength() - 1;
    }

    function testD4_ComposerQueue() public {
        address user = address(0x05E3);
        // NOTE: amounts kept small on purpose — the live UnderlyingOFT escrow holds only
        // ~201 USDC of immediately-settleable USDC (rest is deployed via strategies);
        // a larger local settlement reverts inside UOFT.withdraw (see Zenith I-2, acknowledged).
        uint256 id0 = _enqueueLocal(user, 100e6, 0);
        uint256 id1 = _enqueueLocal(user, 200e6, 0);
        console.log("D4 enqueued ids:", id0, id1);

        // duplicate id in one batch -> second processing reverts -> whole batch reverts (keeper-side DoS only)
        uint256[] memory dup = new uint256[](2);
        dup[0] = id0; dup[1] = id0;
        uint256[] memory fees = new uint256[](2);
        vm.prank(keeper);
        vm.expectRevert();
        IComposerD(COMPOSER).processWithdrawals(dup, fees);
        console.log("D4 duplicate-id batch reverted as expected");

        // cancel id1, then batch [canceled, good] must skip canceled and process good (Zenith L-10 fix)
        vm.prank(user);
        IComposerD(COMPOSER).cancelWithdrawal(id1);
        assertEq(IVaultD(VAULT).balanceOf(user), 200e6, "cancel did not refund shares");
        uint256 usdcBefore = IERC20D(USDC).balanceOf(user);
        uint256[] memory batch = new uint256[](2);
        batch[0] = id1; batch[1] = id0;
        vm.prank(keeper);
        IComposerD(COMPOSER).processWithdrawals(batch, fees);
        uint256 usdcAfter = IERC20D(USDC).balanceOf(user);
        console.log("D4 user USDC from processed local withdrawal:", usdcAfter - usdcBefore);
        assertGt(usdcAfter, usdcBefore, "good entry was not processed");
        ComposerEntry memory e0 = IComposerD(COMPOSER).getWithdrawalQueueEntry(id0);
        assertTrue(e0.fulfilled, "entry0 not marked fulfilled");
    }

    // ---------- D4b: minAmountLD self-brick + cancel escape ----------
    function testD4_MinAmountBrick() public {
        address user = address(0x05E3);
        uint256 id = _enqueueLocal(user, 500e6, type(uint256).max / 2);
        uint256[] memory one = new uint256[](1);
        one[0] = id;
        uint256[] memory f1 = new uint256[](1);
        vm.prank(keeper);
        vm.expectRevert();
        IComposerD(COMPOSER).processWithdrawals(one, f1);
        uint256 balBefore = IVaultD(VAULT).balanceOf(user);
        vm.prank(user);
        IComposerD(COMPOSER).cancelWithdrawal(id);
        assertEq(IVaultD(VAULT).balanceOf(user) - balBefore, 500e6, "cancel escape failed");
        console.log("D4 minAmountLD brick confirmed; cancel escape works");
    }
}

/// @notice Deep-dive fork validation, Ethereum spoke. Areas 3 + 5.
contract ZircuitDeepDiveEthTest is Test {
    address constant VT = 0x07C898e77310870770f88d18a01009cB65A1c1a9;
    address constant ADAPTER = 0xd58E8c1c83d598aD76B5f0E26B4a25cdB885d190;
    address constant USDC_ETH = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant COMPOSER = 0xBb801ED781dF31F660cC743bEf7Bb9D04B030923;
    uint32 constant BASE_EID = 30184;

    function setUp() public {
        vm.createSelectFork("ethereum");
    }

    function _hop2() internal pure returns (SendParam memory) {
        return SendParam({
            dstEid: BASE_EID,
            to: bytes32(uint256(uint160(address(0xBEEF)))),
            amountLD: 0,
            minAmountLD: 0,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
    }

    function _toComposer(uint256 amountLD, bytes memory composeMsg)
        internal
        pure
        returns (SendParam memory)
    {
        return SendParam({
            dstEid: BASE_EID,
            to: bytes32(uint256(uint160(COMPOSER))),
            amountLD: amountLD,
            minAmountLD: 0,
            extraOptions: "",
            composeMsg: composeMsg,
            oftCmd: ""
        });
    }

    // ---------- D5 + Zenith H-1/L-11/L-12 fixes: VaultToken unsigned queue validation on deployed code ----------
    function testD5_VaultTokenUnsignedQueue() public {
        address user = address(0x05E4);
        vm.deal(user, 10 ether);
        deal(VT, user, 1_000e18);
        assertEq(IVaultTokenD(VT).decimals(), 18);

        bytes memory composeMsg = abi.encode(_hop2(), uint256(0));
        // amount with sub-SD dust: 100e18 + 123456789012 wei (< 1e12 = below shared precision)
        uint256 amount = 100e18 + 123_456_789_012;
        SendParam memory sp = _toComposer(amount, composeMsg);
        MessagingFee memory fee = IVaultTokenD(VT).quoteSend(sp, false);
        console.log("D5 quoted native fee:", fee.nativeFee);
        assertGt(fee.nativeFee, 0);

        // (a) underpaying the quoted fee reverts (ZRC-4 / Zenith L-12 family)
        MessagingFee memory lowFee = MessagingFee({ nativeFee: fee.nativeFee - 1, lzTokenFee: 0 });
        vm.prank(user);
        vm.expectRevert();
        IVaultTokenD(VT).send{ value: lowFee.nativeFee }(sp, lowFee, user);

        // (b) dust-only amount rounds to zero -> reverts (Zenith L-12 fix)
        SendParam memory dustSp = _toComposer(999_999_999_999, composeMsg);
        MessagingFee memory dustFee = IVaultTokenD(VT).quoteSend(dustSp, false);
        vm.prank(user);
        vm.expectRevert();
        IVaultTokenD(VT).send{ value: dustFee.nativeFee }(dustSp, dustFee, user);

        // (c) valid enqueue: only the SD-truncated amount is debited; dust stays with the user
        uint256 balBefore = IVaultTokenD(VT).balanceOf(user);
        vm.prank(user);
        IVaultTokenD(VT).send{ value: fee.nativeFee }(sp, fee, user);
        uint256 qlen = IVaultTokenD(VT).getWithdrawalQueueLength();
        console.log("D5 queue length after enqueue:", qlen);
        assertEq(balBefore - IVaultTokenD(VT).balanceOf(user), 100e18, "debit != truncated amount");
        VTEntry memory entry = IVaultTokenD(VT).getWithdrawalQueueEntry(qlen - 1);
        console.log("D5 stored entry amountLD (expect exactly 100e18):", entry.sendParam.amountLD);
        assertEq(entry.sendParam.amountLD, 100e18, "entry stored untruncated amount (Zenith H-1!)");

        // (d) cancel refunds exactly the truncated amount (H-1 over-refund fix) + the prepaid native fee
        uint256 ethBefore = user.balance;
        vm.prank(user);
        IVaultTokenD(VT).cancelWithdrawal(qlen - 1);
        assertEq(IVaultTokenD(VT).balanceOf(user), balBefore, "cancel refund != debited amount");
        assertEq(user.balance - ethBefore, fee.nativeFee, "cancel native refund wrong");
        console.log("D5 cancel refunded truncated amount + fee exactly; H-1/L-11/L-12 fixes verified live");
    }

    // ---------- D3: UnderlyingOFTAdapter destination lock + fee discipline + signed-path rejection ----------
    function testD3_AdapterLocks() public {
        address user = address(0x05E5);
        vm.deal(user, 10 ether);
        deal(USDC_ETH, user, 10_000e6);
        vm.prank(user);
        IERC20D(USDC_ETH).approve(ADAPTER, type(uint256).max);

        bytes memory composeMsg = abi.encode(_hop2(), uint256(0));
        SendParam memory good = _toComposer(100e6, composeMsg);
        MessagingFee memory fee = IAdapterD(ADAPTER).quoteSend(good, false);
        console.log("D3 adapter quoted fee:", fee.nativeFee);

        // (a) wrong destination eid
        SendParam memory badEid = _toComposer(100e6, composeMsg);
        badEid.dstEid = 30101;
        vm.prank(user);
        vm.expectRevert();
        IAdapterD(ADAPTER).send{ value: fee.nativeFee }(badEid, fee, user);

        // (b) wrong recipient (not the hub composer)
        SendParam memory badTo = _toComposer(100e6, composeMsg);
        badTo.to = bytes32(uint256(uint160(user)));
        vm.prank(user);
        vm.expectRevert();
        IAdapterD(ADAPTER).send{ value: fee.nativeFee }(badTo, fee, user);

        // (c) empty composeMsg
        SendParam memory noCompose = _toComposer(100e6, "");
        vm.prank(user);
        vm.expectRevert();
        IAdapterD(ADAPTER).send{ value: fee.nativeFee }(noCompose, fee, user);

        // (d) unsigned path: msg.value above the fee reverts (Zenith L-9 fix pattern)
        vm.prank(user);
        vm.expectRevert();
        IAdapterD(ADAPTER).send{ value: fee.nativeFee + 1 }(good, fee, user);

        // (e) signed path: garbage signature rejected
        bytes memory garbage = new bytes(65);
        vm.prank(user);
        vm.expectRevert();
        IAdapterD(ADAPTER).send{ value: fee.nativeFee }(
            good, fee, user, fee.nativeFee, block.timestamp + 3600, garbage
        );
        console.log("D3 adapter locks + fee discipline + signed-path rejection all hold");
    }
}
