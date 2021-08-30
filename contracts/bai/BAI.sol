// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

enum Frequency {
    UNKNOWN, //0
    DAILY, // 1
    WEEKLY, // 2
    BIWEEKLY, // 3
    MONTHLY, // 4
    // FOR DEVELOPMENT ONLY
    HOURLY, // 5
    PERMINUTE //6
}

interface IBaiController {
    function config(Frequency frequency, uint256 amountPerTime) external;

    function deposit(uint256 amount) external;

    function withdraw(uint256 usdcAmount, uint256 btcAmount)
        external
        returns (bool);

    function swap() external returns (bool);
}

contract BaiController is IBaiController, Context, Ownable, Pausable {
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for IERC20;

    struct Configuration {
        Frequency frequency;
        uint256 amountPerTime;
    }

    struct Tx {
        uint256 timeTraded;
        uint256 amountIn;
        uint256 amountOut;
    }

    IUniswapV2Router02 public immutable uniswapV2Router;
    // address public immutable uniswapV2Pair;
    IERC20 public constant WBTC =
        IERC20(0x577D296678535e4903D59A4C929B718e1D575e0A); // rinkeby // mainnet: 0x2260fac5e5542a773aa44fbcfedf7c193bc2c599 //kovan: 0xd3A691C852CDB01E281545A27064741F0B7f6825
    IERC20 public constant USDC =
        IERC20(0x4DBCdF9B62e891a7cec5A2568C3F4FAF9E8Abe2b); // rinkeby // mainnet: 0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48 //kovan: 0xb7a4F3E9097C08dA09517b5aB877F7a917224ede
    address private constant UNISWAP_ROUTER =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address[] investors;
    mapping(address => Configuration) private configurations;
    mapping(address => uint256) private usdcBalance;
    mapping(address => uint256) private btcBalance;
    mapping(address => Tx[]) private transactions;
    mapping(address => uint256) private lastTraded;
    mapping(address => bool) public exists;
    // mapping(address => uint256) private indexOfInvestors;
    // uint256 private index = 1;
    uint256 public constant MIN_AMOUNT = 10**6 * 100; // min 100 USDC
    uint256 public constant DENOMINATOR = 1e4;
    bool swapInProgress = false;
    uint8 public maxItemsPerStep = 1;

    event UserConfigured(
        address indexed user,
        Frequency frequency,
        uint256 amountPerTime
    );
    event UserToppedUp(address indexed user, uint256 amount);
    event Swapped(
        address indexed tokenOut,
        uint256 amountsOut,
        address indexed tokenIn,
        uint256 amountsIn
    );
    event Withdrawn(
        address indexed user,
        uint256 amountofUsdc,
        uint256 amountOfBtc
    );

    modifier whenNotSwapping() {
        require(!swapInProgress, "Swap in progress.");
        _;
    }

    constructor() {
        // mainnet
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            UNISWAP_ROUTER
        );

        uniswapV2Router = _uniswapV2Router;
    }

    //to recieve ETH from uniswapV2Router when swaping
    receive() external payable {}

    function kill() external onlyOwner {
        uint256 balance = USDC.balanceOf(address(this));
        if (balance > 0) USDC.safeTransfer(_msgSender(), balance);
        balance = WBTC.balanceOf(address(this));
        if (balance > 0) WBTC.safeTransfer(_msgSender(), balance);
        selfdestruct(payable(_msgSender()));
    }

    function setMaxItemPerStep(uint8 step) external onlyOwner {
        maxItemsPerStep = step;
    }

    function config(Frequency frequency, uint256 amountPerTime)
        external
        override
        whenNotPaused
    {
        address user = _msgSender();
        require(amountPerTime > 0, "amount must be non-zero");
        require(
            frequency > Frequency.UNKNOWN &&
                frequency <=
                (block.chainid == 1 ? Frequency.MONTHLY : Frequency.PERMINUTE),
            "invalid frequency"
        );

        configurations[user] = Configuration({
            frequency: frequency,
            amountPerTime: amountPerTime
        });

        if (!exists[user]) {
            investors.push(user);
            exists[user] = true;
        }

        emit UserConfigured(user, frequency, amountPerTime);
    }

    function deposit(uint256 amountOfUSDC) external override whenNotPaused {
        address user = _msgSender();
        require(user != address(0), "zero address");
        require(amountOfUSDC >= MIN_AMOUNT, "Invalid amount of USDC");
        require(
            USDC.allowance(user, address(this)) >= amountOfUSDC,
            "Approval required"
        );
        require(
            amountOfUSDC <= USDC.balanceOf(user),
            "Insufficient balance of USDC"
        );
        USDC.safeTransferFrom(address(user), address(this), amountOfUSDC);

        usdcBalance[user] = usdcBalance[user].add(amountOfUSDC);
        emit UserToppedUp(user, amountOfUSDC);
    }

    function withdraw(uint256 usdcAmount, uint256 btcAmount)
        external
        override
        whenNotPaused
        whenNotSwapping
        returns (bool)
    {
        address _user = _msgSender();
        require(
            usdcAmount > 0 || btcAmount > 0,
            "withdrawal amount must not be zero"
        );
        require(
            usdcBalance[_user] > 0 || btcBalance[_user] > 0,
            "You have no balance to withdraw"
        );
        require(usdcBalance[_user] >= usdcAmount, "Insufficient USDC amount");
        require(btcBalance[_user] >= btcAmount, "Insufficient WBTC amount");

        uint256 _allowanceOfUsdc = USDC.allowance(
            address(this),
            UNISWAP_ROUTER
        );
        uint256 _allowanceOfBtc = WBTC.allowance(address(this), UNISWAP_ROUTER);

        if (_allowanceOfUsdc == 0) USDC.safeApprove(UNISWAP_ROUTER, 2**256 - 1); // infinity approval
        if (_allowanceOfBtc == 0) WBTC.safeApprove(UNISWAP_ROUTER, 2**256 - 1); // infinity approval

        uint256 valOfUsdc = USDC.balanceOf(address(this)) >= usdcAmount
            ? usdcAmount
            : USDC.balanceOf(address(this));
        uint256 valOfBtc = WBTC.balanceOf(address(this)) >= btcAmount
            ? btcAmount
            : WBTC.balanceOf(address(this));

        if (valOfUsdc > 0) USDC.safeTransfer(_user, valOfUsdc);
        if (valOfBtc > 0) WBTC.safeTransfer(_user, valOfBtc);

        if (usdcBalance[_user] == 0) delete usdcBalance[_user];
        else usdcBalance[_user] = usdcBalance[_user].sub(usdcAmount);
        if (btcBalance[_user] == 0) delete btcBalance[_user];
        else btcBalance[_user] = btcBalance[_user].sub(btcAmount);

        if (usdcBalance[_user] == 0 && btcBalance[_user] == 0) {
            delete configurations[_user];
            delete exists[_user];
        }

        emit Withdrawn(_user, valOfUsdc, valOfBtc);

        return true;
    }

    function swap()
        external
        override
        whenNotPaused
        whenNotSwapping
        returns (bool)
    {
        (
            uint256 totalUsdc,
            address[] memory activeInvestors,
            uint256[] memory amounts,
            uint256[] memory percentages,
            bool hasNext
        ) = prepare();

        require(totalUsdc > 0, "No need to swap");
        require(activeInvestors.length > 0, "No users to buy");

        uint256 _usdcBalance = USDC.balanceOf(address(this));
        require(_usdcBalance >= totalUsdc, "Insufficient USDC balance");

        swapInProgress = true;

        uint256 _allowanceOfUsdc = USDC.allowance(
            address(this),
            UNISWAP_ROUTER
        );
        if (_allowanceOfUsdc < totalUsdc)
            USDC.safeApprove(UNISWAP_ROUTER, 2**256 - 1); // infinity approval

        (address[] memory path, uint256 amountsOut) = findBestPath(totalUsdc);
        uint256[] memory outputs = uniswapV2Router.swapExactTokensForTokens(
            totalUsdc,
            amountsOut,
            path,
            address(this),
            block.timestamp + 30 seconds
        );
        uint256 amountOfBTC = outputs[outputs.length - 1];

        for (uint256 i = 0; i < activeInvestors.length; i++) {
            address investor = activeInvestors[i];
            uint256 userBTC = amountOfBTC.mul(percentages[i]).div(DENOMINATOR);

            // add tx
            Tx memory _tx = Tx({
                timeTraded: block.timestamp,
                amountIn: amounts[i],
                amountOut: userBTC
            });
            transactions[investor].push(_tx);

            // change lastTraded
            lastTraded[investor] = block.timestamp;

            // update balance
            usdcBalance[investor] = usdcBalance[investor].sub(amounts[i]);
            btcBalance[investor] = btcBalance[investor].add(userBTC);
        }

        emit Swapped(address(USDC), totalUsdc, address(WBTC), amountOfBTC);

        swapInProgress = false;
        return hasNext;
    }

    function findBestPath(uint256 amountsIn)
        private
        view
        returns (address[] memory path, uint256 amountsOut)
    {
        address[] memory path1 = new address[](2);
        path1[0] = address(USDC);
        path1[1] = address(WBTC);
        uint256[] memory results = uniswapV2Router.getAmountsOut(
            amountsIn,
            path1
        );
        uint256 amountOfBTC1 = results[results.length - 1];

        address[] memory path2 = new address[](3);
        path2[0] = address(USDC);
        path2[1] = uniswapV2Router.WETH();
        path2[2] = address(WBTC);
        results = uniswapV2Router.getAmountsOut(amountsIn, path2);
        uint256 amountOfBTC2 = results[results.length - 1];

        path = amountOfBTC2 > amountOfBTC1 ? path2 : path1;
        amountsOut = Math.max(amountOfBTC1, amountOfBTC2);
    }

    function prepare()
        public
        view
        returns (
            // view
            uint256 totalUsdc,
            address[] memory activeInvestors,
            uint256[] memory amounts,
            uint256[] memory percentages,
            bool hasNext
        )
    {
        Configuration memory _config;
        address currentUser;
        uint256 userLastTraded;

        (uint256 count, bool _hasNext) = getAvailableInvestors();
        require(count > 0, "No need to swap");
        hasNext = _hasNext;
        activeInvestors = new address[](count);
        amounts = new uint256[](count);
        percentages = new uint256[](count);

        uint128 j = 0;
        uint256 len = investors.length >= maxItemsPerStep
            ? maxItemsPerStep
            : investors.length;
        for (uint256 i = 0; i < len; i++) {
            currentUser = investors[i];
            _config = configurations[currentUser];
            userLastTraded = lastTraded[currentUser];

            if (_config.frequency == Frequency.UNKNOWN) continue;
            uint256 duration = getTimeWindowInSeconds(_config.frequency);

            if (
                (userLastTraded == 0 &&
                    usdcBalance[currentUser] >= _config.amountPerTime) ||
                (userLastTraded.add(duration) <= block.timestamp &&
                    usdcBalance[currentUser] >= _config.amountPerTime) // never traded before and has enough balance
            ) {
                if (j == count) break;
                totalUsdc = totalUsdc.add(_config.amountPerTime);
                activeInvestors[j] = currentUser;
                amounts[j] = _config.amountPerTime;

                j++;
            }
        }

        require(activeInvestors[count - 1] != address(0), "Calculation error");

        for (uint256 i = 0; i < activeInvestors.length; i++) {
            percentages[i] = amounts[i].mul(DENOMINATOR).div(totalUsdc);
        }
    }

    function getAvailableInvestors()
        public
        view
        returns (uint256 total, bool hasNext)
    {
        Configuration memory _config;
        address currentUser;
        uint256 userLastTraded;
        uint256 len = investors.length;

        for (uint256 i = 0; i < len; i++) {
            currentUser = investors[i];
            _config = configurations[currentUser];
            userLastTraded = lastTraded[currentUser];

            if (_config.frequency == Frequency.UNKNOWN) continue;
            uint256 duration = getTimeWindowInSeconds(_config.frequency);

            if (
                (userLastTraded == 0 &&
                    usdcBalance[currentUser] >= _config.amountPerTime) ||
                (userLastTraded.add(duration) <= block.timestamp &&
                    usdcBalance[currentUser] >= _config.amountPerTime) // never traded before and has enough balance
            ) {
                total = total.add(1);
                if (total > maxItemsPerStep) break;
            }
        }

        hasNext = total > maxItemsPerStep;
        if (hasNext) total = maxItemsPerStep;
    }

    function totalInvestors() external view returns (uint256) {
        return investors.length;
    }

    function myInfo(address user)
        external
        view
        returns (
            Configuration memory myConfig,
            uint256 myUsdcBalance,
            uint256 myBtcBalance,
            uint256 myLastTraded,
            uint256 totalTxs,
            uint256 nextTrade
        )
    {
        myConfig = configurations[user];
        myUsdcBalance = usdcBalance[user];
        myBtcBalance = btcBalance[user];
        myLastTraded = lastTraded[user];
        totalTxs = transactions[user].length;
        nextTrade = myLastTraded.add(
            getTimeWindowInSeconds(myConfig.frequency)
        );
    }

    function myTransactions(address user) external view returns (Tx[] memory) {
        return transactions[user];
    }

    function myTransactionsByPage(
        address user,
        uint256 page,
        uint256 size
    ) external view returns (Tx[] memory) {
        Tx[] memory txs = transactions[user];
        if (txs.length > 0) {
            uint256 from = page == 0 ? 0 : (page - 1) * size;
            uint256 to = Math.min((page == 0 ? 1 : page) * size, txs.length);
            Tx[] memory infos = new Tx[]((to - from));
            for (uint256 i = 0; from < to; ++i) {
                infos[i] = txs[from];
                ++from;
            }
            return infos;
        } else {
            return new Tx[](0);
        }
    }

    function myTransactionsByPageDesc(
        address user,
        uint256 page,
        uint256 size
    ) external view returns (Tx[] memory) {
        Tx[] memory txs = transactions[user];

        if (txs.length > 0) {
            uint256 from = txs.length - 1 - (page == 0 ? 0 : (page - 1) * size);
            uint256 to = txs.length -
                1 -
                Math.min((page == 0 ? 1 : page) * size - 1, txs.length - 1);
            uint256 resultSize = from - to + 1;
            Tx[] memory infos = new Tx[](resultSize);
            if (to == 0) {
                for (uint256 i = 0; from > to; ++i) {
                    infos[i] = txs[from];
                    --from;
                }
                infos[resultSize - 1] = txs[0];
            } else {
                for (uint256 i = 0; from >= to; ++i) {
                    infos[i] = txs[from];
                    --from;
                }
            }
            return infos;
        }
        return new Tx[](0);
    }

    function getTimeWindowInSeconds(Frequency frequency)
        private
        pure
        returns (uint256)
    {
        uint256 totalSeconds = frequency == Frequency.DAILY
            ? 1 days
            : frequency == Frequency.WEEKLY
            ? 1 weeks
            : frequency == Frequency.BIWEEKLY
            ? 2 weeks
            : frequency == Frequency.MONTHLY
            ? 4 weeks
            : frequency == Frequency.HOURLY
            ? 1 hours
            : frequency == Frequency.PERMINUTE
            ? 1 minutes
            : 0;

        // require(totalSeconds > 0, 'Invalid frequency value');
        return totalSeconds;
    }

    function getChainId() public view returns (uint256) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }
}
