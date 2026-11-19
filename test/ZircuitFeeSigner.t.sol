// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";

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

struct WithdrawalQueueEntry {
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

interface IVaultTokenSigned {
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress,
        uint256 _approvedValue,
        uint256 _deadline,
        bytes calldata _signature
    ) external payable;
    function getWithdrawalQueueLength() external view returns (uint256);
    function getWithdrawalQueueEntry(uint256 _index) external view returns (WithdrawalQueueEntry memory);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @notice FeeSigner validation on Ethereum fork against deployed VaultToken proxies.
/// Deployed _validateSignature hash = keccak256(abi.encode(address(this), block.chainid,
/// msg.sender, keccak256(abi.encode(sendParam)), approvedValue, deadline));
/// usedHash keyed by that hash; ECDSA lib = custom (s-bound + ecrecover-0 revert).
abstract contract FeeSignerBase is Test {
    address constant VT_USDC = 0x07C898e77310870770f88d18a01009cB65A1c1a9;
    address constant VT_USDT = 0x8ADbeA709B31A564f9750A280EC2690aD1cf470A;
    address constant COMPOSER_USDC = 0xBb801ED781dF31F660cC743bEf7Bb9D04B030923;
    address constant COMPOSER_USDT = 0x16cE6D9576A411911e62b6073F1cc9d1347ad96B;
    address constant REAL_SIGNER = 0x88909Ed19313D67b48C808cC2855237249a320C3;
    uint32 constant BASE_EID = 30184;
    // namespaced VaultToken storage base (verified on-chain 19 Nov 2026:
    // +0 composer, +1 eid|tmpComposeFrom, +2 queue length, +3 usedHash, +4 feeSigner)
    bytes32 constant STORAGE_BASE = 0xe0913ae125bb6bd87bc7d157a02ebd350d4fb7b6de4f250370254c3648545400;
    uint256 constant SECP_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    uint256 internal signerKey = 0xFE3519E11E1E11CE;
    address internal backend;
    address internal user = address(0xA11CE);
    address internal other = address(0xB0B);
    uint256 internal amount;
    uint256 internal approved = 0.05 ether;

    function _err(string memory sig) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(bytes4(keccak256(bytes(sig))));
    }

    function _sendParam(address token) internal view returns (SendParam memory sp) {
        address composer = token == VT_USDC ? COMPOSER_USDC : COMPOSER_USDT;
        SendParam memory secondHop;
        secondHop.dstEid = 30101; // back to Ethereum
        secondHop.to = bytes32(uint256(uint160(user)));
        secondHop.amountLD = 0;
        secondHop.minAmountLD = 0;
        sp.dstEid = BASE_EID;
        sp.to = bytes32(uint256(uint160(composer)));
        sp.amountLD = amount;
        sp.minAmountLD = amount;
        sp.extraOptions = new bytes(0);
        sp.composeMsg = abi.encode(secondHop, uint256(0.001 ether));
        sp.oftCmd = new bytes(0);
    }

    function _quoteHash(address token, address sender, SendParam memory sp, uint256 appr, uint256 dl)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(token, block.chainid, sender, keccak256(abi.encode(sp)), appr, dl));
    }

    function _sign(uint256 key, bytes32 h) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, h);
        return abi.encodePacked(r, s, v);
    }

    function _usedHash(address token, bytes32 h) internal view returns (bool) {
        bytes32 slot = keccak256(abi.encode(h, uint256(STORAGE_BASE) + 3));
        return uint256(vm.load(token, slot)) != 0;
    }

    function _call(address token, SendParam memory sp, address refund, uint256 appr, uint256 dl, bytes memory sig, uint256 value)
        internal
    {
        IVaultTokenSigned(token).send{ value: value }(sp, MessagingFee(0, 0), refund, appr, dl, sig);
    }
}

/// @notice Control: with the REAL live feeSigner, a signature from any other key must fail.
contract FeeSignerRealSignerTest is FeeSignerBase {
    function setUp() public {
        vm.createSelectFork("ethereum");
        address liveSigner = address(uint160(uint256(vm.load(VT_USDC, bytes32(uint256(STORAGE_BASE) + 4)))));
        console.log("live feeSigner (fork):", liveSigner);
        assertEq(liveSigner, REAL_SIGNER, "unexpected live feeSigner");
        uint8 dec = IVaultTokenSigned(VT_USDC).decimals();
        amount = 10_000 * (10 ** uint256(dec));
        deal(VT_USDC, user, amount * 10);
        vm.deal(user, 10 ether);
    }

    function testFS_RealSignerRejectsForeignSignature() public {
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 dl = block.timestamp + 3600;
        bytes32 h = _quoteHash(VT_USDC, user, sp, approved, dl);
        bytes memory sig = _sign(0xBADBEEF, h); // not the backend key
        vm.prank(user);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDC, sp, user, approved, dl, sig, approved);
        console.log("FS-real: foreign signature rejected against live feeSigner", REAL_SIGNER);
    }
}

/// @notice Main suite: feeSigner slot overridden ON THE FORK ONLY to a test backend key,
/// so valid quotes can be produced and every binding/replay/malleability property exercised.
contract FeeSignerTest is FeeSignerBase {
    function setUp() public {
        vm.createSelectFork("ethereum");
        backend = vm.addr(signerKey);
        vm.store(VT_USDC, bytes32(uint256(STORAGE_BASE) + 4), bytes32(uint256(uint160(backend))));
        vm.store(VT_USDT, bytes32(uint256(STORAGE_BASE) + 4), bytes32(uint256(uint160(backend))));
        uint8 dec = IVaultTokenSigned(VT_USDC).decimals();
        amount = 10_000 * (10 ** uint256(dec));
        deal(VT_USDC, user, amount * 10);
        deal(VT_USDT, user, amount * 10);
        vm.deal(user, 10 ether);
        vm.deal(other, 10 ether);
    }

    function _validSig(address token, address sender, SendParam memory sp, uint256 appr, uint256 dl)
        internal
        view
        returns (bytes memory)
    {
        return _sign(signerKey, _quoteHash(token, sender, sp, appr, dl));
    }

    // Happy path + state effects: queue entry signedQuote=true, fee=(0,0), txFee=full msg.value, usedHash set.
    function testFS_ValidQuoteAccepted() public {
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 dl = block.timestamp + 3600;
        bytes memory sig = _validSig(VT_USDC, user, sp, approved, dl);
        uint256 qBefore = IVaultTokenSigned(VT_USDC).getWithdrawalQueueLength();
        uint256 balBefore = IVaultTokenSigned(VT_USDC).balanceOf(address(uint160(VT_USDC)));
        vm.prank(user);
        _call(VT_USDC, sp, user, approved, dl, sig, approved);
        assertEq(IVaultTokenSigned(VT_USDC).getWithdrawalQueueLength(), qBefore + 1, "queue did not grow");
        assertEq(IVaultTokenSigned(VT_USDC).balanceOf(VT_USDC), balBefore + amount, "shares not escrowed");
        assertTrue(_usedHash(VT_USDC, _quoteHash(VT_USDC, user, sp, approved, dl)), "usedHash not set");
        WithdrawalQueueEntry memory e = IVaultTokenSigned(VT_USDC).getWithdrawalQueueEntry(qBefore);
        assertTrue(e.signedQuote, "signedQuote flag false");
        assertEq(e.fee.nativeFee, 0, "signed entry fee.nativeFee should be 0");
        assertEq(e.txFee, approved, "signed entry txFee should be full msg.value");
        console.log("FS1: valid quote accepted; entry signedQuote=true, fee=0, txFee=msg.value, usedHash set");
    }

    // Replay: identical quote a second time -> SignatureAlreadyUsed.
    function testFS_ReplayReverts() public {
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 dl = block.timestamp + 3600;
        bytes memory sig = _validSig(VT_USDC, user, sp, approved, dl);
        vm.prank(user);
        _call(VT_USDC, sp, user, approved, dl, sig, approved);
        vm.prank(user);
        vm.expectRevert(_err("SignatureAlreadyUsed()"));
        _call(VT_USDC, sp, user, approved, dl, sig, approved);
        console.log("FS2: replay of the same quote reverts SignatureAlreadyUsed");
    }

    // Cross-user: quote bound to msg.sender; another user cannot spend it.
    function testFS_CrossUserReverts() public {
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 dl = block.timestamp + 3600;
        bytes memory sig = _validSig(VT_USDC, user, sp, approved, dl);
        deal(VT_USDC, other, amount * 10);
        vm.prank(other);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDC, sp, other, approved, dl, sig, approved);
        console.log("FS3: quote is bound to msg.sender; cross-user use reverts");
    }

    // Tampering: any change to sendParam / approvedValue after signing invalidates the quote.
    function testFS_TamperedParamsRevert() public {
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 dl = block.timestamp + 3600;
        bytes memory sig = _validSig(VT_USDC, user, sp, approved, dl);
        SendParam memory sp2 = _sendParam(VT_USDC);
        sp2.amountLD = amount * 2;
        sp2.minAmountLD = amount * 2;
        vm.prank(user);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDC, sp2, user, approved, dl, sig, approved * 2);
        vm.prank(user);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDC, sp, user, approved + 1, dl, sig, approved + 1);
        console.log("FS4: tampered amountLD and tampered approvedValue both revert (full binding)");
    }

    // Underpayment: msg.value < approvedValue reverts even with a valid signature.
    function testFS_UnderpaidReverts() public {
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 dl = block.timestamp + 3600;
        bytes memory sig = _validSig(VT_USDC, user, sp, approved, dl);
        vm.prank(user);
        vm.expectRevert(_err("MsgValueLowerThanApproved()"));
        _call(VT_USDC, sp, user, approved, dl, sig, approved - 1);
        console.log("FS5: msg.value below approvedValue reverts MsgValueLowerThanApproved");
    }

    // Expiry: deadline is enforced AND bound in the hash (cannot be extended by the caller).
    function testFS_DeadlineEnforcedAndBound() public {
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 dlPast = block.timestamp - 1;
        bytes memory sigExpired = _validSig(VT_USDC, user, sp, approved, dlPast);
        vm.prank(user);
        vm.expectRevert(_err("QuoteSignatureExpired()"));
        _call(VT_USDC, sp, user, approved, dlPast, sigExpired, approved);
        uint256 dl = block.timestamp + 3600;
        bytes memory sig = _validSig(VT_USDC, user, sp, approved, dl);
        vm.prank(user);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDC, sp, user, approved, dl + 7200, sig, approved);
        console.log("FS6: expired quote reverts; caller-side deadline extension reverts (deadline is signed)");
    }

    // Malleability: high-s counterpart signature is rejected by the custom ECDSA lib.
    function testFS_MalleabilityReverts() public {
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 dl = block.timestamp + 3600;
        bytes32 h = _quoteHash(VT_USDC, user, sp, approved, dl);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, h);
        bytes32 s2 = bytes32(SECP_N - uint256(s));
        uint8 v2 = v == 27 ? 28 : 27;
        bytes memory malleated = abi.encodePacked(r, s2, v2);
        vm.prank(user);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDC, sp, user, approved, dl, malleated, approved);
        console.log("FS7: malleated (high-s) signature reverts; s-bound enforced in custom ECDSA");
    }

    // Garbage / short signatures: ecrecover-0 path reverts inside tryRecover.
    function testFS_GarbageSignatureReverts() public {
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 dl = block.timestamp + 3600;
        bytes memory garbage = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(1)), uint8(27));
        vm.prank(user);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDC, sp, user, approved, dl, garbage, approved);
        bytes memory shortSig = new bytes(64);
        vm.prank(user);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDC, sp, user, approved, dl, shortSig, approved);
        console.log("FS8: garbage (ecrecover=0) and 64-byte signatures revert");
    }

    // feeSigner == address(0): NO zero-address bypass (ecrecover-0 reverts before comparison);
    // a real signature from another key also fails comparison -> signed path is bricked, not open.
    function testFS_ZeroSignerNoBypass() public {
        vm.store(VT_USDC, bytes32(uint256(STORAGE_BASE) + 4), bytes32(0));
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 dl = block.timestamp + 3600;
        bytes memory garbage = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(1)), uint8(27));
        vm.prank(user);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDC, sp, user, approved, dl, garbage, approved);
        bytes memory sig = _validSig(VT_USDC, user, sp, approved, dl);
        vm.prank(user);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDC, sp, user, approved, dl, sig, approved);
        console.log("FS9: feeSigner=0 gives no bypass; signed path reverts for every signature (bricked, not open)");
    }

    // Cross-contract: quote bound to address(this); USDC quote is invalid on the USDT proxy (same impl).
    function testFS_CrossContractReverts() public {
        SendParam memory sp = _sendParam(VT_USDT);
        uint256 dl = block.timestamp + 3600;
        // signed as if for the USDC contract (hash carries VT_USDC), submitted to VT_USDT
        bytes memory sig = _sign(signerKey, _quoteHash(VT_USDC, user, sp, approved, dl));
        vm.prank(user);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDT, sp, user, approved, dl, sig, approved);
        console.log("FS10: quote bound to contract address; cross-contract replay reverts");
    }

    // Cross-chain: hash carries block.chainid; a quote hashed for another chain is invalid here.
    function testFS_CrossChainReverts() public {
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 dl = block.timestamp + 3600;
        bytes32 foreignHash = keccak256(abi.encode(VT_USDC, uint256(56), user, keccak256(abi.encode(sp)), approved, dl));
        bytes memory sig = _sign(signerKey, foreignHash);
        vm.prank(user);
        vm.expectRevert(_err("ECDSAInvalidSignature()"));
        _call(VT_USDC, sp, user, approved, dl, sig, approved);
        console.log("FS11: quote bound to chainid; foreign-chain quote reverts");
    }

    // Informational: _refundAddress and _fee are NOT in the signed hash.
    // The initiator may freely choose their own refund address; overpaying msg.value is also
    // accepted (approvedValue is a minimum). All value at risk is the initiator's own.
    function testFS_RefundAddressNotBound_Info() public {
        address refundA = address(0xBEF0A);
        address refundB = address(0xBEF0B);
        SendParam memory sp = _sendParam(VT_USDC);
        uint256 q0 = IVaultTokenSigned(VT_USDC).getWithdrawalQueueLength();
        uint256 dl1 = block.timestamp + 3600;
        vm.prank(user);
        _call(VT_USDC, sp, refundA, approved, dl1, _validSig(VT_USDC, user, sp, approved, dl1), approved);
        uint256 dl2 = block.timestamp + 7200;
        vm.prank(user);
        _call(VT_USDC, sp, refundB, approved, dl2, _validSig(VT_USDC, user, sp, approved, dl2), approved + 0.01 ether);
        WithdrawalQueueEntry memory e1 = IVaultTokenSigned(VT_USDC).getWithdrawalQueueEntry(q0);
        WithdrawalQueueEntry memory e2 = IVaultTokenSigned(VT_USDC).getWithdrawalQueueEntry(q0 + 1);
        assertEq(e1.refundAddress, refundA, "entry1 refundAddress");
        assertEq(e2.refundAddress, refundB, "entry2 refundAddress");
        assertEq(e2.txFee, approved + 0.01 ether, "overpay becomes txFee in full");
        console.log("FS12(info): refundAddress is caller-chosen post-signature (own funds only); overpay accepted, txFee=full msg.value");
    }
}
