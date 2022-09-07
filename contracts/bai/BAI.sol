// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.7;
pragma abicoder v2;

// import "hardhat/console.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

// import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "./ArrayHelper.sol";

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

contract BaiController is
    IBaiController,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using ArrayHelper for ArrayHelper.Inner;

    struct Configuration {
        Frequency frequency;
        uint256 amountPerTime;
    }

    struct Tx {
        uint256 timeTraded;
        uint256 amountIn;
        uint256 amountOut;
    }

    ISwapRouter public swapRouter;
    address public pool;
    IQuoter public quoter;
    // address public immutable uniswapV2Pair;
    IERC20Upgradeable public WBTC; // =
    // IERC20Upgradeable(0x577D296678535e4903D59A4C929B718e1D575e0A); // rinkeby // mainnet: 0x2260fac5e5542a773aa44fbcfedf7c193bc2c599 //kovan: 0xd3A691C852CDB01E281545A27064741F0B7f6825
    IERC20Upgradeable public USDC; // =
    // IERC20Upgradeable(0x4DBCdF9B62e891a7cec5A2568C3F4FAF9E8Abe2b); // rinkeby // mainnet: 0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48 //kovan: 0xb7a4F3E9097C08dA09517b5aB877F7a917224ede
    // address private constant address(swapRouter) = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address[] investors;
    mapping(address => Configuration) private configurations;
    mapping(address => uint256) private usdcBalance;
    mapping(address => uint256) private btcBalance;
    mapping(address => Tx[]) private transactions;
    mapping(address => uint256) private lastTraded;
    mapping(address => bool) public exists;
    uint256 public constant MIN_AMOUNT = 10**6 * 10; // min 10 USDC
    uint256 public constant DENOMINATOR = 1e4;
    bool swapInProgress = false;
    uint8 public maxItemsPerStep;
    uint16 public fee = 10; // by default 0.1%;
    address public feeCollector;
    uint256 public totalFees = 0;
    uint24[2][] public multihopFees = [[500, 500], [500, 3000]];
    ArrayHelper.Inner _investors;

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
    event FeeCollected(address indexed collector, uint256 totalFees);
    event PathFound(uint24[2] fees, uint256 amountsOut);

    modifier whenNotSwapping() {
        require(!swapInProgress, "Swap in progress.");
        _;
    }

    modifier onlyFeeCollector() {
        require(_msgSender() == feeCollector, "collector required");
        _;
    }

    function initialize(
        address ownerAccount,
        address wbtc,
        address usdc,
        address uniswapRouter,
        address quoterAddress
    ) public initializer whenNotPaused {
        require(ownerAccount != address(0), "BAI::constructor:Zero address");

        WBTC = IERC20Upgradeable(wbtc);
        USDC = IERC20Upgradeable(usdc);
        maxItemsPerStep = 100;

        // mainnet
        swapRouter = ISwapRouter(uniswapRouter);
        quoter = IQuoter(quoterAddress);

        _setupRole(DEFAULT_ADMIN_ROLE, ownerAccount);

        // Paused on launch
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        _unpause();
    }

    //to recieve ETH from swapRouter when swaping
    receive() external payable {}

    function upgradeOnce() external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < investors.length; i++) {
            _investors.add(investors[i]);
        }
    }

    function kill() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 balance = USDC.balanceOf(address(this));
        if (balance > 0) USDC.safeTransfer(_msgSender(), balance);
        balance = WBTC.balanceOf(address(this));
        if (balance > 0) WBTC.safeTransfer(_msgSender(), balance);
        selfdestruct(payable(_msgSender()));
    }

    function setMultihopFees(uint24[2][] memory _fees)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        multihopFees = _fees;
    }

    function setSwapRouter(address _router)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(address(swapRouter) != _router, "no change");
        swapRouter = ISwapRouter(_router);
    }

    function setMaxItemPerStep(uint8 step)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        maxItemsPerStep = step;
    }

    function setFee(uint16 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFee != fee, "no change");
        fee = newFee;
    }

    function setFeeCollector(address _newFeeCollector)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_newFeeCollector != address(0), "zero address");
        require(_newFeeCollector != feeCollector, "no change");
        feeCollector = _newFeeCollector;
    }

    function collectFees() external onlyFeeCollector {
        require(totalFees > 0, "no fee");
        require(feeCollector != address(0), "feeCollector is zero");
        uint256 balance = WBTC.balanceOf(address(this));
        if (balance >= totalFees) WBTC.safeTransfer(feeCollector, totalFees);
        else WBTC.safeTransfer(feeCollector, balance);

        emit FeeCollected(
            feeCollector,
            MathUpgradeable.min(balance, totalFees)
        );
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
                (block.chainid == 10 ? Frequency.MONTHLY : Frequency.PERMINUTE),
            "invalid frequency"
        );

        configurations[user] = Configuration({
            frequency: frequency,
            amountPerTime: amountPerTime
        });

        _investors.add(user);

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

        usdcBalance[user] = usdcBalance[user] + (amountOfUSDC);
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
        // require(USDC.balanceOf(address(this)) >= usdcBalance[_user], 'Insufficient USDC on BAI');
        // require(WBTC.balanceOf(address(this)) >= btcBalance[_user], 'Insufficient WBTC on BAI');

        uint256 _allowanceOfUsdc = USDC.allowance(
            address(this),
            address(swapRouter)
        );
        uint256 _allowanceOfBtc = WBTC.allowance(
            address(this),
            address(swapRouter)
        );

        if (_allowanceOfUsdc == 0)
            USDC.safeApprove(address(swapRouter), 2**256 - 1); // infinity approval
        if (_allowanceOfBtc == 0)
            WBTC.safeApprove(address(swapRouter), 2**256 - 1); // infinity approval

        uint256 valOfUsdc = USDC.balanceOf(address(this)) >= usdcAmount
            ? usdcAmount
            : USDC.balanceOf(address(this));
        uint256 valOfBtc = WBTC.balanceOf(address(this)) >= btcAmount
            ? btcAmount
            : WBTC.balanceOf(address(this));

        if (valOfUsdc > 0) USDC.safeTransfer(_user, valOfUsdc);
        if (valOfBtc > 0) WBTC.safeTransfer(_user, valOfBtc);

        if (usdcBalance[_user] == 0) delete usdcBalance[_user];
        else usdcBalance[_user] = usdcBalance[_user] - (usdcAmount);
        if (btcBalance[_user] == 0) delete btcBalance[_user];
        else btcBalance[_user] = btcBalance[_user] - (btcAmount);

        if (usdcBalance[_user] == 0 && btcBalance[_user] == 0) {
            delete configurations[_user];
            _investors.remove(_user);
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
            address(swapRouter)
        );
        if (_allowanceOfUsdc < totalUsdc)
            USDC.safeApprove(address(swapRouter), 2**256 - 1); // infinity approval

        (
            bool isMultihop,
            uint256 amountsOut,
            uint24[2] memory fees
        ) = findBestPath(totalUsdc);

        uint256 amountOfBTC;
        if (isMultihop) {
            amountOfBTC = swapRouter.exactInput(
                getMultihopParams(totalUsdc, amountsOut, fees)
            );
        } else {
            amountOfBTC = swapRouter.exactInputSingle(
                getSingleParams(totalUsdc, amountsOut)
            );
        }

        amountOfBTC = deductFees(amountOfBTC);

        for (uint256 i = 0; i < activeInvestors.length; i++) {
            address investor = activeInvestors[i];
            uint256 userBTC = (amountOfBTC * (percentages[i])) / (DENOMINATOR);

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
            usdcBalance[investor] = usdcBalance[investor] - (amounts[i]);
            btcBalance[investor] = btcBalance[investor] + (userBTC);
        }

        emit Swapped(address(USDC), totalUsdc, address(WBTC), amountOfBTC);

        swapInProgress = false;
        return hasNext;
    }

    function deductFees(uint256 amountOfBTC) private returns (uint256 leftBTC) {
        leftBTC = (amountOfBTC * (DENOMINATOR - (fee))) / (DENOMINATOR);
        totalFees = totalFees + (amountOfBTC - (leftBTC));
    }

    function getMultihopParams(
        uint256 amountsIn,
        uint256 amountOutMinimum,
        uint24[2] memory fees
    ) public view returns (ISwapRouter.ExactInputParams memory) {
        return
            ISwapRouter.ExactInputParams({
                path: getEncodedPath(fees),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountsIn,
                amountOutMinimum: amountOutMinimum
            });
    }

    function getSingleParams(uint256 amountsIn, uint256 amountOutMinimum)
        public
        view
        returns (ISwapRouter.ExactInputSingleParams memory)
    {
        return
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(WBTC),
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountsIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            });
    }

    function findBestPath(uint256 amountsIn)
        public
        returns (
            bool isMultihop,
            uint256 amountsOut,
            uint24[2] memory fees
        )
    {
        uint256 singleQuote = quoter.quoteExactInputSingle(
            address(USDC),
            address(WBTC),
            uint24(3000), //fee
            amountsIn,
            0 // sqrtPriceLimitX96
        );

        uint256 multihopQuote = 0;
        for (uint24 i = 0; i < multihopFees.length; i++) {
            uint256 out = quoter.quoteExactInput(
                getEncodedPath(multihopFees[i]),
                amountsIn
            );
            if (out > multihopQuote) {
                fees = multihopFees[i];
                multihopQuote = out;
            }
        }

        isMultihop = multihopQuote > singleQuote ? true : false;
        amountsOut = multihopQuote > singleQuote ? multihopQuote : singleQuote;

        emit PathFound(isMultihop ? fees : [uint24(0), uint24(0)], amountsOut);
    }

    function getEncodedPath(uint24[2] memory fees)
        public
        view
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                address(USDC),
                fees[0],
                IPeripheryImmutableState(address(swapRouter)).WETH9(),
                fees[1],
                address(WBTC)
            );
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
        uint256 len = _investors.length() >= maxItemsPerStep
            ? maxItemsPerStep
            : _investors.length();
        for (uint256 i = 0; i < len; i++) {
            currentUser = _investors.getByIndex(i);
            _config = configurations[currentUser];
            userLastTraded = lastTraded[currentUser];

            if (_config.frequency == Frequency.UNKNOWN) continue;
            uint256 duration = getTimeWindowInSeconds(_config.frequency);

            if (
                (userLastTraded == 0 &&
                    usdcBalance[currentUser] >= _config.amountPerTime) ||
                (userLastTraded + (duration) <= block.timestamp &&
                    usdcBalance[currentUser] >= _config.amountPerTime) // never traded before and has enough balance
            ) {
                if (j == count) break;
                totalUsdc = totalUsdc + (_config.amountPerTime);
                activeInvestors[j] = currentUser;
                amounts[j] = _config.amountPerTime;

                j++;
            }
        }

        require(activeInvestors[count - 1] != address(0), "Calculation error");

        for (uint256 i = 0; i < activeInvestors.length; i++) {
            percentages[i] = (amounts[i] * (DENOMINATOR)) / (totalUsdc);
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
        uint256 len = _investors.length();

        for (uint256 i = 0; i < len; i++) {
            currentUser = _investors.getByIndex(i);
            _config = configurations[currentUser];
            userLastTraded = lastTraded[currentUser];

            if (_config.frequency == Frequency.UNKNOWN) continue;
            uint256 duration = getTimeWindowInSeconds(_config.frequency);

            if (
                (userLastTraded == 0 &&
                    usdcBalance[currentUser] >= _config.amountPerTime) ||
                (userLastTraded + (duration) <= block.timestamp &&
                    usdcBalance[currentUser] >= _config.amountPerTime) // never traded before and has enough balance
            ) {
                total = total + (1);
                if (total > maxItemsPerStep) break;
            }
        }

        hasNext = total > maxItemsPerStep;
        if (hasNext) total = maxItemsPerStep;
    }

    function totalInvestors() external view returns (uint256) {
        return _investors.length();
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
        nextTrade = myLastTraded + (getTimeWindowInSeconds(myConfig.frequency));
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
            uint256 to = MathUpgradeable.min(
                (page == 0 ? 1 : page) * size,
                txs.length
            );
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
                MathUpgradeable.min(
                    (page == 0 ? 1 : page) * size - 1,
                    txs.length - 1
                );
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

        return totalSeconds;
    }

    function getChainId() public view returns (uint256) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }

    // function checkUpkeep(
    //     bytes calldata /* checkData */
    // )
    //     external
    //     override
    //     returns (
    //         bool upkeepNeeded,
    //         bytes memory /*performData*/
    //     )
    // {
    //     (uint256 totalUsdc, , , , ) = prepare();
    //     upkeepNeeded = (totalUsdc > 0);
    //     // performData = hasNext;
    // }

    // function performUpkeep(
    //     bytes calldata /* performData */
    // ) external override {
    //     swap();
    // }
}
