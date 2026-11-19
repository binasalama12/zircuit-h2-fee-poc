// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";
import { MockStrategy4626 } from "../src/MockStrategy.sol";

interface IERC20D {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IStrategyManagerD {
    function allowStrategy(address strategy, bool allowed) external;
    function deployFunds(address strategy, uint256 amount, uint256 minShares) external returns (uint256);
    function freeFunds(address strategy, uint256 shares, uint256 minUnderlying) external returns (uint256);
    function reportDelta(address strategy) external payable;
    function getUnderlyingByStrategy(address strategy) external view returns (int256);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IERC4626D {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IVaultD {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Fork validation (companion to ZircuitValidation.t.sol, H2):
/// A third-party DONATION of underlying directly to a live strategy (plain ERC20
/// transfer, no shares issued, no yield produced) is reported by StrategyManager
/// as a positive delta, and AccountingReceiver charges the 20% performance fee
/// on it exactly as if it were profit.
contract ZircuitDonationTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SM = 0xf7E745658fa6f1fe8f2CAb47861a273991Cd3374;
    address constant VAULT = 0x03067bbD0d41E3Fe4A0bb6ca67c99e7352Da4CAE;
    address constant FEE_RECIPIENT = 0x6941bDF233c09f557165EF720049c1A67839F56e;

    bytes32 constant ROLE_ALLOC = keccak256("ALLOCATION_MANAGER");
    bytes32 constant ROLE_REPORT = keccak256("REPORTING_MANAGER");
    bytes32 constant ROLE_STRATEGY = keccak256("STRATEGY_MANAGER");

    address allocator = address(0xA110C);
    address reporter = address(0x8E907);
    address stratAdmin = address(0x57A7E);
    address donor = address(0xD0407);

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
        // Same fork block as the original H2 validation run (poc-output.txt).
        vm.createSelectFork("base", 59447119);
        console.log("fork block:", block.number);

        _grantRole(SM, ROLE_ALLOC, allocator);
        _grantRole(SM, ROLE_REPORT, reporter);
        _grantRole(SM, ROLE_STRATEGY, stratAdmin);
        require(IStrategyManagerD(SM).hasRole(ROLE_ALLOC, allocator), "alloc role grant failed");
        require(IStrategyManagerD(SM).hasRole(ROLE_REPORT, reporter), "report role grant failed");
        require(IStrategyManagerD(SM).hasRole(ROLE_STRATEGY, stratAdmin), "strategy role grant failed");

        deal(USDC, SM, 5_000_000e6);
        mock = new MockStrategy4626(USDC);
        vm.prank(stratAdmin);
        IStrategyManagerD(SM).allowStrategy(address(mock), true);
    }

    function pps() internal view returns (uint256) {
        return (IVaultD(VAULT).totalAssets() * 1e18) / IVaultD(VAULT).totalSupply();
    }

    function _report(address strategy) internal returns (int256 dAssets) {
        uint256 a0 = IVaultD(VAULT).totalAssets();
        vm.prank(reporter);
        IStrategyManagerD(SM).reportDelta(strategy);
        uint256 a1 = IVaultD(VAULT).totalAssets();
        dAssets = int256(a1) - int256(a0);
    }

    /// @dev Expected fee shares for a +10,000e6 mint delta under the deployed
    /// conversion mechanics: the fee leg (2,000e6) is deposited into the Vault AFTER
    /// the net-of-fee delta (8,000e6) has been minted into the Vault's asset base but
    /// before any new shares exist for this delta (OZ ERC4626 previewDeposit).
    function _expectedFeeShares() internal view returns (uint256) {
        return (2_000e6 * (IVaultD(VAULT).totalSupply() + 1)) / (IVaultD(VAULT).totalAssets() + 8_000e6 + 1);
    }

    function testDonationChargedPerformanceFee() public {
        address m = address(mock);

        // Deploy 100k into the strategy through the real StrategyManager; baseline report is zero.
        vm.prank(allocator);
        IStrategyManagerD(SM).deployFunds(m, 100_000e6, 0);
        assertEq(_report(m), 0, "initial report not zero");
        assertEq(IStrategyManagerD(SM).getUnderlyingByStrategy(m), int256(100_000e6));

        console.log("DON PPS start x1e18:", pps());
        console.log("DON recipient shares start:", IVaultD(VAULT).balanceOf(FEE_RECIPIENT));
        console.log("DON vault totalAssets pre-report:", IVaultD(VAULT).totalAssets());
        console.log("DON vault totalSupply pre-report:", IVaultD(VAULT).totalSupply());
        uint256 smShares0 = IERC4626D(m).balanceOf(SM);
        uint256 mockSupply0 = IERC4626D(m).totalSupply();
        uint256 expectedFeeShares = _expectedFeeShares();
        console.log("DON expected fee shares (OZ deposit formula):", expectedFeeShares);

        // Third-party donation: plain USDC transfer to the strategy contract.
        // No shares are issued to the donor, no position is opened, no yield exists.
        deal(USDC, donor, 10_000e6);
        vm.prank(donor);
        require(IERC20D(USDC).transfer(m, 10_000e6), "donation transfer failed");
        console.log("DON donor USDC balance after donation:", IERC20D(USDC).balanceOf(donor));
        console.log("DON donor vault shares (expect 0):", IVaultD(VAULT).balanceOf(donor));
        assertEq(IERC4626D(m).balanceOf(SM), smShares0, "SM strategy shares changed by donation");
        assertEq(IERC4626D(m).totalSupply(), mockSupply0, "mock share supply changed by donation");

        // Routine keeper report: the donation is reported as a +10,000 positive delta.
        uint256 rBefore = IVaultD(VAULT).balanceOf(FEE_RECIPIENT);
        int256 dDon = _report(m);
        uint256 feeShares = IVaultD(VAULT).balanceOf(FEE_RECIPIENT) - rBefore;
        console.log("DON report dAssets (expect +10000e6):", dDon);
        console.log("DON fee shares minted on the donation:", feeShares);
        console.log("DON fee value at end PPS (USDC wei):", (feeShares * pps()) / 1e18);
        console.log("DON PPS end x1e18:", pps());
        console.log("DON recipient shares end:", IVaultD(VAULT).balanceOf(FEE_RECIPIENT));

        assertEq(dDon, int256(10_000e6), "donation delta != +10000e6");
        assertGt(feeShares, 0, "no fee charged on donation - hypothesis not reproduced");
        assertApproxEqAbs(feeShares, expectedFeeShares, 1, "fee shares != deposit-formula expectation");
        // 20% of the 10,000 USDC donation is 2,000 USDC; fee shares are worth just under that.
        assertGt((feeShares * pps()) / 1e18, 1_900e6, "fee value on donation too small");
        assertEq(IStrategyManagerD(SM).getUnderlyingByStrategy(m), int256(110_000e6));

        // cleanup state (shares read BEFORE prank so the prank is not consumed by it)
        uint256 cleanupShares = IERC4626D(m).balanceOf(SM);
        vm.prank(allocator);
        IStrategyManagerD(SM).freeFunds(m, cleanupShares, 0);
    }
}
