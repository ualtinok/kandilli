const { ethers } = require("ethers");
const args = process.argv.slice(2);

const abi = JSON.parse(
  '[{"inputs":[{"components":[{"internalType":"string","name":"name","type":"string"}],"internalType":"struct Data","name":"data","type":"tuple"}],"name":"foo","outputs":[],"stateMutability":"nonpayable","type":"function"}]'
);
const iface = new ethers.utils.Interface(abi);

const data = [["r" + Math.random()]];
// TODO: Is there a better way to do this, instead of fake-encoding
// as a function and stripping the function selector?
encoded = iface.encodeFunctionData("foo", data);
process.stdout.write("0x" + encoded.slice(10));
