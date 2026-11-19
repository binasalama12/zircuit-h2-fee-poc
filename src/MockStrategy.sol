// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Minimal ERC-4626 strategy with configurable deposit/exit haircut,
/// used to exercise StrategyManager basis accounting on a Base fork.
/// Shares are minted 1:1 against *net* deposited assets; convertToAssets is
/// pro-rata over the live USDC balance, so yield = deal() USDC in,
/// loss = slash() USDC out.
contract MockStrategy4626 {
    IERC20Min public immutable assetToken;
    uint256 public depositFeeBps; // taken on deposit (sent to dead address = real economic loss)
    uint256 public exitFeeBps; // taken on redeem

    string public name = "Mock Strategy Share";
    string public symbol = "MOCK";
    uint8 public decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address _asset) {
        assetToken = IERC20Min(_asset);
    }

    function setFees(uint256 _depBps, uint256 _exitBps) external {
        depositFeeBps = _depBps;
        exitFeeBps = _exitBps;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function totalAssets() public view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalSupply == 0) return shares;
        return (shares * totalAssets()) / totalSupply;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 ta = totalAssets();
        if (ta == 0) return assets;
        return (assets * totalSupply) / ta;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        uint256 fee = (assets * depositFeeBps) / 10000;
        uint256 net = assets - fee;
        // compute shares against PRE-deposit state (first deposit mints 1:1)
        shares = totalSupply == 0 ? net : (net * totalSupply) / totalAssets();
        require(assetToken.transferFrom(msg.sender, address(this), assets), "pull failed");
        if (fee > 0) {
            require(assetToken.transfer(address(0xdead), fee), "fee out failed");
        }
        totalSupply += shares;
        balanceOf[receiver] += shares;
        emit Transfer(address(0), receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(balanceOf[owner] >= shares, "insufficient shares");
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            require(allowed >= shares, "insufficient allowance");
            allowance[owner][msg.sender] = allowed - shares;
        }
        uint256 gross = convertToAssets(shares);
        uint256 fee = (gross * exitFeeBps) / 10000;
        assets = gross - fee;
        totalSupply -= shares;
        balanceOf[owner] -= shares;
        emit Transfer(owner, address(0), shares);
        if (fee > 0) {
            require(assetToken.transfer(address(0xdead), fee), "fee out failed");
        }
        require(assetToken.transfer(receiver, assets), "pay failed");
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = convertToShares(assets);
        // reuse redeem logic via internal path
        require(balanceOf[owner] >= shares, "insufficient shares");
        totalSupply -= shares;
        balanceOf[owner] -= shares;
        emit Transfer(owner, address(0), shares);
        require(assetToken.transfer(receiver, assets), "pay failed");
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = totalSupply == 0 ? shares : (shares * totalAssets()) / totalSupply;
        require(assetToken.transferFrom(msg.sender, address(this), assets), "pull failed");
        totalSupply += shares;
        balanceOf[receiver] += shares;
        emit Transfer(address(0), receiver, shares);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice Simulate an economic loss: burn `amount` of held USDC.
    function slash(uint256 amount) external {
        require(assetToken.transfer(address(0xdead), amount), "slash failed");
    }
}
