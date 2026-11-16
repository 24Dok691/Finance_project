import { network } from "hardhat";

const { ethers } = await network.connect();

async function main() {
  const [admin, treasury, sme, buyer, investor] = await ethers.getSigners();
  console.log("Deploying EsepInvoiceEscrow to local Hardhat Network...");

  const Factory = await ethers.getContractFactory("EsepInvoiceEscrow");
  const escrow = await Factory.deploy(treasury.address);
  await escrow.waitForDeployment();
  console.log("Contract deployed at:", await escrow.getAddress());

  await escrow.grantRole(await escrow.SME_ROLE(), sme.address);
  await escrow.grantRole(await escrow.BUYER_ROLE(), buyer.address);
  await escrow.grantRole(await escrow.INVESTOR_ROLE(), investor.address);

  const hash = ethers.keccak256(ethers.toUtf8Bytes("DEMO-INV-2026-888"));
  const faceValue = ethers.parseEther("10.0");
  const dueDate = Math.floor(Date.now() / 1000) + 86400 * 60;

  console.log("1. SME registering invoice hash:", hash);
  await (await escrow.connect(sme).registerInvoice(hash, buyer.address, faceValue, dueDate)).wait();

  console.log("2. Corporate buyer verifying invoice...");
  await (await escrow.connect(buyer).verifyInvoice(hash)).wait();

  console.log("3. Investor funding invoice at 5% discount (9.5 units)...");
  await (await escrow.connect(investor).fundInvoice(hash, { value: ethers.parseEther("9.5") })).wait();

  console.log("4. Buyer settling full face value (10.0 units) to investor...");
  await (await escrow.connect(buyer).settleInvoice(hash, { value: faceValue })).wait();

  const finalState = await escrow.invoices(hash);
  console.log("Final Invoice Status (3 = Settled):", finalState.status.toString());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});