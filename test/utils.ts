import { ethers } from "hardhat";
import { assert, expect } from "chai";
import { BigNumber, BigNumberish, constants, utils } from "ethers";

export interface BlockInfo {
    number: number;
    timestamp: number;
}

export const getBlockInfo = async () => {
    const blockNumber = await ethers.provider.getBlockNumber();
    return {
        number: blockNumber,
        timestamp: (await ethers.provider.getBlock(blockNumber)).timestamp,
    } as BlockInfo;
};

export const getBlockTimestamp = async () => {
    const blockNumber = await ethers.provider.getBlockNumber();
    return (await ethers.provider.getBlock(blockNumber)).timestamp;
};

export const sleep = async (seconds: number) => {
    await ethers.provider.send("evm_increaseTime", [seconds]);
};

export const mine = async () => {
    await ethers.provider.send("evm_mine", []);
};

export const divf = (a: number, b: number) => {
    return Math.floor(a / b);
};

export const PRECISION_BASE = constants.WeiPerEther;

export const expectApproxEqual = (
    a: BigNumberish,
    b: BigNumberish,
    precision = PRECISION_BASE.div(BigNumber.from(10).pow(10))
) => {
    a = BigNumber.from(a);
    b = BigNumber.from(b);
    if (a.eq(b) && b.eq(0)) return;
    assert(
        a.sub(b).abs().mul(2).lte(a.add(b).mul(precision).div(PRECISION_BASE)),
        `${utils.formatEther(a)} and ${utils.formatEther(
            b
        )} isn't approximately equal with precision ${utils.formatEther(precision)}`
    );
};

export const expectZero = (value: BigNumberish) => {
    expect(value).to.be.equal(0);
};

export const randomArray = (min: BigNumberish, max: BigNumberish, count: number) => {
    const array: BigNumber[] = [];
    const range = BigNumber.from(max).sub(min);
    for (let i = 0; i < count; i++) {
        const value = utils.parseEther(Math.random().toFixed(18)).mul(range).div(constants.WeiPerEther);
        array.push(BigNumber.from(min).add(value));
    }
    return array;
};

export const randomMatrix = (min: BigNumberish, max: BigNumberish, row: number, col: number) => {
    const matrix: BigNumber[][] = [];
    const range = BigNumber.from(max).sub(min);
    for (let i = 0; i < col; i++) {
        const data: BigNumber[] = [];
        for (let j = 0; j < row; j++) {
            const value = utils.parseEther(Math.random().toFixed(18)).mul(range).div(constants.WeiPerEther);
            data.push(BigNumber.from(min).add(value));
        }
        matrix.push(data);
    }
    return matrix;
};
