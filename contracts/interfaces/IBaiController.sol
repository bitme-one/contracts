// SPDX-License-Identifier: MIT

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

    // function swap() external returns (bool);
}
