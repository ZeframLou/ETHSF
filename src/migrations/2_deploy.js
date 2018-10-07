var Portfolio = artifacts.require("Portfolio");
var ERC20 = artifacts.require("ERC20");

module.exports = async function(deployer) {
    deployer.then(async () => {
        var PRECISION = 1e18;
        var DAI_ADDRESS = "0x8870946B0018E2996a7175e8380eb0d43dD09EFE";
    
        var assetList = [
            "0xCd43d7410295E54922a2C3CF6F2Dd1BD7D18AbD1", // Salt
            "0x0fA1727EE15Cc6afAB7305e03E06237de66B5EC4", // Status Network
            "0xd0A1E359811322d97991E03f863a0C30C2cF029C"  // Wrapped ETH
        ];
        var fractionList = [
            0.5 * PRECISION, // 50%
            0.3 * PRECISION, // 30%
            0.2 * PRECISION  // 20%
        ];
        var collateralInDAI = 10 * PRECISION;
    
        await deployer.deploy(Portfolio, assetList, fractionList, collateralInDAI);
        var port = await Portfolio.deployed();
        await ERC20.at(DAI_ADDRESS).approve(port.address, collateralInDAI);
    });
};