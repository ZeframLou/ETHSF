pragma solidity ^0.4.24;

import "./dharma/DebtKernel.sol";
import "./dharma/RepaymentRouter.sol";
import "./kyber/KyberNetworkProxyInterface.sol";
import "zeppelin/ownership/Ownable.sol";
import "zeppelin/math/SafeMath.sol";
import "./set/ISetToken.sol";
import "./set/ICore.sol";
import "./set/ISetFactory.sol";
import "./kyber/ERC20Interface.sol";

contract Portfolio is Ownable {
    using SafeMath for uint256;

    address public constant KYBER = 0x0;
    address public constant TERMS_CONTRACT = 0x0;
    address public constant DEBT_KERNEL = 0x0;
    address public constant REPAYMENT_ROUTER = 0x0;
    address public constant SET_CORE = 0x0;
    address public constant SET_FACTORY = 0x0;
    uint256 public constant PRECISION = 10 ** 18;
    uint256 public constant MAX_AMOUNT = 10 ** 28;

    address public setTokenAddress;
    address public borrowedTokenAddress;
    address[] public assetList;
    uint256[] public fractionList;

    KyberNetworkProxyInterface public kyber;
    DebtKernal public debtKernel;
    RepaymentRouter public repaymentRouter;
    ICore public setCore;
    ISetFactory public setFactory;

    ISetToken public setToken;
    ERC20 public borrowedToken;

    constructor (address _borrowedToken) public {
        borrowedTokenAddress = _borrowedToken;
        borrowedToken = ERC20(_borrowedToken);

        kyber = KyberNetworkProxyInterface(KYBER);
        debtKernel = DebtKernel(DEBT_KERNEL);
        repaymentRouter = RepaymentRouter(REPAYMENT_ROUTER);
        setCore = ICore(SET_CORE);
    }

    function startPortfolio(
        address creditor,
        address[6] orderAddresses,
        uint[8] orderValues,
        bytes32[1] orderBytes32,
        uint8[3] signaturesV,
        bytes32[3] signaturesR,
        bytes32[3] signaturesS
    ) public onlyOwner {
        uint256 beforeTokenBalance = borrowedToken.balanceOf(this);

        // fill debt order and get funds
        bytes32 agreementId = debtKernel.fillDebtOrder(creditor, orderAddresses, orderValues, orderBytes32, signaturesV, signaturesR, signaturesS);

        // calculate received loan
        uint256 receivedLoan = borrowedToken.balanceOf(this).sub(beforeTokenBalance);

        // buy tokens using Kyber
        bytes memory hint;
        uint256[] destAmountList;
        for (uint256 i = 0; i < assetList.length; i++) {
            uint256 slippage;
            uint256 srcAmount = receivedLoan.mul(fractionList[i]).div(PRECISION);
            (,slippage) = getExpectedRate(borrowedToken, assetList[i], srcAmount);
            destAmountList.push(tradeWithHint(borrowedToken, srcAmount, components[i], this, MAX_AMOUNT,
                slippage, 0, hint));
        }

        // create SetToken
        
    }
}