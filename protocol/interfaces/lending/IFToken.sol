// SPDX-License-Identifier: MIT

pragma solidity 0.6.6;
import "./IERC20.sol";

interface IFToken is IERC20Interface {

    function transferToUser(
        address token,
        address payable user,
        uint256 amount
    ) external;

    function transferIn(
        uint256 amount
    ) internal payable;

    function borrow(uint256 borrowAmount)
        external;

    function withdrawTokens(
        uint256 withdrawTokensIn
    ) external returns (uint256);

    function underlying() external view returns (address);

    function accrueInterest() external;

    function getAccountState(address account)
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        );

    function repay(uint256 repayAmount) payable external;

    function borrowBalanceStored(address account)
        external
        view
        returns (uint256);

    function exchangeRateStored() external view returns (uint256 exchangeRate);

    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        address fTokenCollateral
    ) external payable;

    function borrowBalanceCurrent(address account) external returns (uint256);

    function _reduceReserves(uint256 reduceAmount) external;

    function _addReservesFresh(uint256 addAmount) external;

    function borrowSafeRatio() external view returns (uint256);

    function tokenCash(address token, address account)
        external
        view
        returns (uint256);

    function getBorrowRate() external view returns (uint256);

    function addTotalCash(uint256 _addAmount) external;
    function subTotalCash(uint256 _subAmount) external;

    function totalCash() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function totalBorrows() external view returns (uint256);


}
