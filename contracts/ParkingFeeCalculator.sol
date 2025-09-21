// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, ebool, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/**
 * @title ParkingFeeCalculator
 * @notice 🅿️ Калькулятор парковки на FHE:
 *  - Вход: зашифрованные минуты (euint64)
 *  - Округление до блоков по 30 мин: ceil(minutes / 30) БЕЗ деления
 *  - Стоимость: blocks * pricePerBlock (в центах)
 *  - Дешифровка: только пользователем (relayer.userDecrypt)
 */
contract ParkingFeeCalculator is SepoliaConfig {
    /* ─── Константы и владелец ─────────────────────────────────────────── */
    uint64 public constant BLOCK_MINUTES = 30;
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint64 pricePerBlock_, uint16 maxBlocks_) {
        require(pricePerBlock_ > 0, "price=0");
        require(maxBlocks_ > 0, "maxBlocks=0");
        owner = msg.sender;
        pricePerBlock = pricePerBlock_;
        maxBlocks = maxBlocks_;
    }

    function transferOwnership(address n) external onlyOwner {
        require(n != address(0), "Zero owner");
        owner = n;
    }

    function version() external pure returns (string memory) {
        return "ParkingFeeCalculator/1.0.3-sepolia";
    }

    /* ─── Параметры тарифа ──────────────────────────────────────────────── */
    /// @notice Цена за один 30-минутный блок, в центах
    uint64 public pricePerBlock;

    /// @notice Сколько блоков максимум учитываем (например, 96 = 48 часов)
    uint16 public maxBlocks;

    function setPricePerBlock(uint64 newPrice) external onlyOwner {
        require(newPrice > 0, "price=0");
        pricePerBlock = newPrice;
    }

    function setMaxBlocks(uint16 newMax) external onlyOwner {
        require(newMax > 0, "maxBlocks=0");
        maxBlocks = newMax;
    }

    /* ─── Хранилище персональных результатов ───────────────────────────── */
    mapping(address => euint64) private _lastFee; // последний рассчитанный платёж (зашифрованно)

    /* ─── События ──────────────────────────────────────────────────────── */
    event Quoted(address indexed user, bytes32 feeHandle);

    /* ─── Публичные геттеры хэндлов ────────────────────────────────────── */
    function getMyFeeHandle() external view returns (bytes32) {
        return FHE.toBytes32(_lastFee[msg.sender]);
    }

    /* ─── Внутр. помощник: позиция старшего бита у uint16 ──────────────── */
    function _msbPos(uint16 x) internal pure returns (uint8) {
        uint8 p = 0;
        while (x > 1) {
            x >>= 1;
            unchecked {
                ++p;
            }
        }
        return p; // для x>=1 вернёт позицию старшего бита (0-based)
    }

    /* ─── Основная логика ──────────────────────────────────────────────── */

    /**
     * @notice Рассчитать платёж за зашифрованные минуты и сохранить шифротекст,
     *         доступный пользователю для дешифровки (userDecrypt).
     * @param minutesExt  Внешнее euint64 (зашифрованные минуты)
     * @param proof       Attestation от Relayer SDK для minutesExt
     * @return feeHandle  bytes32-хэндл на шифротекст суммы
     */
    function quote(externalEuint64 minutesExt, bytes calldata proof) external returns (bytes32 feeHandle) {
        require(proof.length > 0, "Empty proof");

        // 1) Импортируем зашифрованные минуты
        euint64 rem = FHE.fromExternal(minutesExt, proof);

        // 2) Быстрый подсчёт floor(minutes / 30) без div:
        //    бинарным «вычитанием крупными кусками» 30 * 2^k.
        //    Потом добавим +1, если остаток > 0 (ceil).
        euint64 blocks = FHE.asEuint64(0);

        // возьмём максимум по старшему биту maxBlocks (достаточно ~16 итераций)
        uint8 kMax = _msbPos(maxBlocks); // 0..15 для maxBlocks<=65535

        // идём k = kMax..0
        for (uint8 ki = kMax + 1; ki > 0; ) {
            unchecked {
                --ki;
            }
            uint8 k = ki;
            // chunk = 30 * (1 << k)
            uint64 chunk = uint64(BLOCK_MINUTES) * (uint64(1) << k);

            // Проверяем rem >= chunk. В lib может не быть gte, используем gt(rem, chunk-1)
            ebool ge = FHE.gt(rem, FHE.asEuint64(chunk - 1));

            // rem = ge ? (rem - chunk) : rem
            euint64 remMinus = FHE.sub(rem, FHE.asEuint64(chunk));
            rem = FHE.select(ge, remMinus, rem);

            // blocks = ge ? (blocks + (1 << k)) : blocks
            euint64 addBy = FHE.asEuint64(uint64(1) << k);
            euint64 blocksPlus = FHE.add(blocks, addBy);
            blocks = FHE.select(ge, blocksPlus, blocks);
        }

        // ceil: если остаток > 0, добавить 1 блок
        ebool hasRem = FHE.gt(rem, FHE.asEuint64(0));
        blocks = FHE.select(hasRem, FHE.add(blocks, FHE.asEuint64(1)), blocks);

        // 3) Ограничим блоки сверху maxBlocks
        ebool tooMany = FHE.gt(blocks, FHE.asEuint64(maxBlocks));
        blocks = FHE.select(tooMany, FHE.asEuint64(maxBlocks), blocks);

        // 4) fee = blocks * pricePerBlock (в центах)
        euint64 fee = FHE.mul(blocks, FHE.asEuint64(pricePerBlock));

        // 5) Сохраняем платёж и выдаём права:
        _lastFee[msg.sender] = fee;

        // — контракту: чтобы переиспользовать это значение в будущем
        FHE.allowThis(_lastFee[msg.sender]);

        // — пользователю: чтобы он мог сделать userDecrypt через Relayer SDK
        FHE.allow(_lastFee[msg.sender], msg.sender);

        // 6) Возвращаем хэндл пользователю
        feeHandle = FHE.toBytes32(_lastFee[msg.sender]);
        emit Quoted(msg.sender, feeHandle);
    }
}
