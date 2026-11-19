// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";
import { MockStrategy4626 } from "../src/MockStrategy.sol";

interface IERC20V {
    function balanceOf(address) external view returns (uint256);
}

interface IStrategyManager {
    function allowStrategy(address strategy, bool allowed) external;
    function deployFunds(address strategy, uint256 amount, uint256 minShares) external returns (uint256);
    function freeFunds(address strategy, uint256 shares, uint256 minUnderlying) external returns (uint256);
    function reportDelta(address strategy) external payable;
    function getUnderlyingByStrategy(address strategy) external view returns (int256);
    function getStrategies() external view returns (address[] memory);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IERC4626V {
    function balanceOf(address) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IVaultV {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Fork validation of Zircuit Finance USDC cluster on Base.
/// H1: StrategyManager signed-basis asymmetry (deploy nominal vs free actual + _removeDust sign truncation)
/// H2: AccountingReceiver performance fee (live 2000 bps) charged on gross positive deltas, no high-water mark.
contract ZircuitValidationTest is Test {
    // Base mainnet deployed addresses (from brief.md / attack-surface.md)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SM = 0xf7E745658fa6f1fe8f2CAb47861a273991Cd3374;
    address constant AR = 0x7fCeB53b2959861D29057361158a2B41cAAffD68;
    address constant VAULT = 0x03067bbD0d41E3Fe4A0bb6ca67c99e7352Da4CAE;
    address constant UOFT = 0xd7aBC360dfcF1B6dD0a03138235e12A2bc1c1C8B;
    address constant FEE_RECIPIENT = 0x6941bDF233c09f557165EF720049c1A67839F56e;

    bytes32 constant SM_STORAGE = 0xeee24b1068db1f77995529a239f6d9b26635e7162ee18ce6dabc59845aabd700;
    bytes32 constant AR_STORAGE = 0x0a59346b4263bf167da6b54c661b0c1738408553996dca1ef40c4dab71da0a00;

    bytes32 constant ROLE_ALLOC = keccak256("ALLOCATION_MANAGER");
    bytes32 constant ROLE_REPORT = keccak256("REPORTING_MANAGER");
    bytes32 constant ROLE_STRATEGY = keccak256("STRATEGY_MANAGER");

    address allocator = address(0xA110C);
    address reporter = address(0x8E907);
    address stratAdmin = address(0x57A7E);

    MockStrategy4626 mock1;
    MockStrategy4626 mock2;
    MockStrategy4626 mock3;

    function _grantRole(address target, bytes32 role, address account) internal {
        // OpenZeppelin v5 AccessControl ERC-7201 storage
        bytes32 base = keccak256(
            abi.encode(uint256(keccak256("openzeppelin.storage.AccessControl")) - 1)
        ) & ~bytes32(uint256(0xff));
        bytes32 roleDataSlot = keccak256(abi.encode(role, base));
        bytes32 memberSlot = keccak256(abi.encode(account, roleDataSlot));
        vm.store(target, memberSlot, bytes32(uint256(1)));
    }

    function setUp() public {
        vm.createSelectFork("base");
        console.log("fork block:", block.number);

        _grantRole(SM, ROLE_ALLOC, allocator);
        _grantRole(SM, ROLE_REPORT, reporter);
        _grantRole(SM, ROLE_STRATEGY, stratAdmin);
        require(IStrategyManager(SM).hasRole(ROLE_ALLOC, allocator), "alloc role grant failed");
        require(IStrategyManager(SM).hasRole(ROLE_REPORT, reporter), "report role grant failed");
        require(IStrategyManager(SM).hasRole(ROLE_STRATEGY, stratAdmin), "strategy role grant failed");

        deal(USDC, SM, 5_000_000e6);
        require(IERC20V(USDC).balanceOf(SM) >= 5_000_000e6, "USDC deal to SM failed");

        mock1 = new MockStrategy4626(USDC);
        mock2 = new MockStrategy4626(USDC);
        mock3 = new MockStrategy4626(USDC);
        vm.prank(stratAdmin);
        IStrategyManager(SM).allowStrategy(address(mock1), true);
        vm.prank(stratAdmin);
        IStrategyManager(SM).allowStrategy(address(mock2), true);
        vm.prank(stratAdmin);
        IStrategyManager(SM).allowStrategy(address(mock3), true);
    }

    function pps() internal view returns (uint256) {
        return (IVaultV(VAULT).totalAssets() * 1e18) / IVaultV(VAULT).totalSupply();
    }

    function _report(address strategy) internal returns (int256 dAssets) {
        uint256 a0 = IVaultV(VAULT).totalAssets();
        vm.prank(reporter);
        IStrategyManager(SM).reportDelta(strategy);
        uint256 a1 = IVaultV(VAULT).totalAssets();
        dAssets = int256(a1) - int256(a0);
    }

    function _deploy(address strategy, uint256 amount) internal {
        vm.prank(allocator);
        IStrategyManager(SM).deployFunds(strategy, amount, 0);
    }

    function _freeAll(address strategy) internal returns (uint256 received) {
        uint256 shares = IERC4626V(strategy).balanceOf(SM);
        vm.prank(allocator);
        received = IStrategyManager(SM).freeFunds(strategy, shares, 0);
    }

    function _free(address strategy, uint256 shares) internal returns (uint256 received) {
        vm.prank(allocator);
        received = IStrategyManager(SM).freeFunds(strategy, shares, 0);
    }

    // ---------- Live configuration evidence ----------
    function testLiveConfig() public {
        bytes32 packed = vm.load(SM, bytes32(uint256(SM_STORAGE) + 2));
        uint256 rate = uint256(vm.load(SM, bytes32(uint256(SM_STORAGE) + 5)));
        uint256 feeBps = uint256(vm.load(AR, bytes32(uint256(AR_STORAGE) + 3)));
        address recip = address(uint160(uint256(vm.load(AR, bytes32(uint256(AR_STORAGE) + 4)))));
        console.log("SM sharedDecimals (low byte of packed slot):", uint256(uint8(uint256(packed))));
        console.log("SM decimalConversionRate:", rate);
        console.log("AR performanceFeeBps (live):", feeBps);
        console.log("AR fee recipient:", recip);
        console.log("Vault totalAssets:", IVaultV(VAULT).totalAssets());
        console.log("Vault crossChainTotalSupply:", IVaultV(VAULT).totalSupply());
        console.log("PPS x1e18:", pps());
        assertEq(rate, 1, "rate != 1");
        assertEq(feeBps, 2000, "feeBps != 2000");

        address[] memory strats = IStrategyManager(SM).getStrategies();
        console.log("live strategies:", strats.length);
        for (uint256 i = 0; i < strats.length; i++) {
            int256 basis = IStrategyManager(SM).getUnderlyingByStrategy(strats[i]);
            uint256 val = IERC4626V(strats[i]).convertToAssets(IERC4626V(strats[i]).balanceOf(SM));
            console.log("strategy:", strats[i]);
            console.log("  basis:", basis);
            console.log("  value:", val);
        }
    }

    // ---------- H1: basis invariant across deploy/free/report ----------
    function testH1_BasisInvariant() public {
        address m = address(mock1);
        int256 d;

        // S1: deploy 100k, +5k yield, report -> mint exactly +5k (incl. fee leg landing in vault)
        _deploy(m, 100_000e6);
        assertEq(IStrategyManager(SM).getUnderlyingByStrategy(m), int256(100_000e6));
        deal(USDC, m, IERC20V(USDC).balanceOf(m) + 5_000e6); // yield: mock balance 100k -> 105k
        d = _report(m);
        console.log("S1 report dAssets (expect +5000e6):", d);
        assertEq(d, int256(5_000e6), "S1 mint != yield");
        assertEq(IStrategyManager(SM).getUnderlyingByStrategy(m), int256(105_000e6));

        // S2: +8k UNREPORTED yield, free ALL (realize 113k), report -> mint exactly +8k, basis -> 0
        deal(USDC, m, IERC20V(USDC).balanceOf(m) + 8_000e6);
        uint256 received = _freeAll(m);
        console.log("S2 freeAll received (expect 113000e6):", received);
        assertEq(received, 113_000e6);
        int256 basisAfterFree = IStrategyManager(SM).getUnderlyingByStrategy(m);
        console.log("S2 basis after free (expect -8000e6):", basisAfterFree);
        assertEq(basisAfterFree, -int256(8_000e6));
        d = _report(m);
        console.log("S2 report dAssets (expect +8000e6 realized yield):", d);
        assertEq(d, int256(8_000e6), "S2 mint != realized yield");
        assertEq(IStrategyManager(SM).getUnderlyingByStrategy(m), 0);

        // S3: 2% deposit haircut -> report burns exactly the haircut
        mock1.setFees(200, 0);
        _deploy(m, 100_000e6);
        assertEq(IStrategyManager(SM).getUnderlyingByStrategy(m), int256(100_000e6));
        d = _report(m);
        console.log("S3 report dAssets (expect -2000e6 haircut):", d);
        assertEq(d, -int256(2_000e6), "S3 burn != haircut");
        assertEq(IStrategyManager(SM).getUnderlyingByStrategy(m), int256(98_000e6));
        mock1.setFees(0, 0);

        // S4: 10% economic loss -> report burns exactly the loss
        mock1.slash(9_800e6);
        d = _report(m);
        console.log("S4 report dAssets (expect -9800e6):", d);
        assertEq(d, -int256(9_800e6), "S4 burn != loss");
        assertEq(IStrategyManager(SM).getUnderlyingByStrategy(m), int256(88_200e6));

        // S5: free half the shares (no unreported P&L) -> report is a no-op; then +5.9k yield -> mint 5.9k
        uint256 shares = IERC4626V(m).balanceOf(SM);
        uint256 rec5 = _free(m, shares / 2);
        console.log("S5 free half received (expect 44100e6):", rec5);
        assertEq(rec5, 44_100e6);
        d = _report(m);
        console.log("S5 report dAssets (expect 0):", d);
        assertEq(d, 0, "S5 phantom delta");
        deal(USDC, m, IERC20V(USDC).balanceOf(m) + 5_900e6);
        d = _report(m);
        console.log("S5b report dAssets (expect +5900e6):", d);
        assertEq(d, int256(5_900e6), "S5b mint != yield");
        _freeAll(m);
        d = _report(m);
        assertEq(d, 0, "S5c phantom delta after full free + report");
        assertEq(IStrategyManager(SM).getUnderlyingByStrategy(m), 0);
    }

    // ---------- H1: wei-level exactness (rate = 1 => _removeDust is identity) ----------
    function testH1_WeiLevelExactness() public {
        address m = address(mock2);
        _deploy(m, 1_000_003); // 1.000003 USDC in wei units
        deal(USDC, m, IERC20V(USDC).balanceOf(m) + 7); // +7 wei yield
        int256 d = _report(m);
        console.log("wei-level report dAssets (expect +7):", d);
        assertEq(d, int256(7), "wei-level drift");
        assertEq(IStrategyManager(SM).getUnderlyingByStrategy(m), int256(1_000_010));
    }

    // ---------- H2: performance fee on oscillating NAV (no high-water mark) ----------
    function testH2_OscillationFeeDrag() public {
        address m = address(mock3);
        _deploy(m, 100_000e6);
        int256 d0 = _report(m);
        assertEq(d0, 0, "initial report not zero");

        uint256 pps0 = pps();
        uint256 recipShares0 = IVaultV(VAULT).balanceOf(FEE_RECIPIENT);
        console.log("H2 PPS start x1e18:", pps0);
        console.log("H2 recipient shares start:", recipShares0);

        uint256 totalFeesShares = 0;
        for (uint256 cycle = 1; cycle <= 3; cycle++) {
            // up leg: +10k yield, report -> mint 10k, fee 20% = 2k taken as shares
            uint256 rBefore = IVaultV(VAULT).balanceOf(FEE_RECIPIENT);
            deal(USDC, m, IERC20V(USDC).balanceOf(m) + 10_000e6);
            int256 dUp = _report(m);
            uint256 rAfter = IVaultV(VAULT).balanceOf(FEE_RECIPIENT);
            console.log("cycle up-leg dAssets (expect +10000e6):", dUp);
            assertEq(dUp, int256(10_000e6), "up-leg mint wrong");
            console.log("cycle fee shares minted:", rAfter - rBefore);
            totalFeesShares += (rAfter - rBefore);

            // down leg: -10k loss, report -> burn 10k, NO fee refund
            mock3.slash(10_000e6);
            int256 dDown = _report(m);
            console.log("cycle down-leg dAssets (expect -10000e6):", dDown);
            assertEq(dDown, -int256(10_000e6), "down-leg burn wrong");
        }

        uint256 ppsEnd = pps();
        uint256 recipSharesEnd = IVaultV(VAULT).balanceOf(FEE_RECIPIENT);
        uint256 feeValueDelta = (totalFeesShares * ppsEnd) / 1e18;
        console.log("H2 net strategy performance over 3 cycles: 0 (ends at 100k deployed value)");
        console.log("H2 fee shares minted by the 3 cycles (delta):", totalFeesShares);
        console.log("H2 value of those fee shares at end PPS (USDC wei):", feeValueDelta);
        console.log("H2 recipient total shares end (incl. pre-existing live balance):", recipSharesEnd);
        console.log("H2 PPS end x1e18:", ppsEnd);
        console.log("H2 PPS drag (start-end) x1e18:", pps0 - ppsEnd);
        // Strategy ends exactly where it started (100k), yet ~6k USDC of fees were extracted.
        assertGt(feeValueDelta, 5_900e6, "fee drag too small - hypothesis not reproduced");
        assertLt(ppsEnd, pps0, "PPS did not drop despite zero net yield");
        // cleanup state
        _freeAll(m);
    }
}
