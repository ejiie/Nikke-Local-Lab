import argparse
import json
from pathlib import Path

import pefile
from capstone import CS_ARCH_X86, CS_MODE_64, Cs
from capstone.x86_const import X86_OP_IMM, X86_OP_MEM, X86_REG_RIP


KNOWN_TARGETS = {
    0x3D98B20: "System.String.Split(char,StringSplitOptions)",
    0x3D93710: "System.String.IndexOf(char)",
    0x3D99280: "System.String.Substring(int,int)",
    0x3E84810: "System.Int32.TryParse(string,int&)",
    0x3E87780: "System.Math.Max(int,int)",
    0x18DA160: "Dictionary.set_Item(shared)",
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--start-rva", type=lambda value: int(value, 0),
                        default=0x648BC80)
    parser.add_argument("--size", type=lambda value: int(value, 0),
                        default=0x798)
    parser.add_argument("--string-literals", type=Path)
    args = parser.parse_args()

    string_literals = {}
    if args.string_literals:
        with args.string_literals.open("r", encoding="utf-8") as stream:
            for entry in json.load(stream):
                string_literals[int(entry["address"], 16)] = entry["value"]

    pe = pefile.PE(str(args.image), fast_load=True)
    image_base = pe.OPTIONAL_HEADER.ImageBase
    offset = pe.get_offset_from_rva(args.start_rva)
    with args.image.open("rb") as stream:
        stream.seek(offset)
        code = stream.read(args.size)

    disassembler = Cs(CS_ARCH_X86, CS_MODE_64)
    disassembler.detail = True
    for instruction in disassembler.disasm(
            code, image_base + args.start_rva):
        annotation = ""
        if instruction.mnemonic == "call" and instruction.operands and \
                instruction.operands[0].type == X86_OP_IMM:
            target_va = instruction.operands[0].imm
            target_rva = target_va - image_base
            name = KNOWN_TARGETS.get(target_rva)
            annotation = f" ; call_rva=0x{target_rva:x}"
            if name:
                annotation += f" {name}"
        rip_targets = []
        for operand in instruction.operands:
            if operand.type == X86_OP_MEM and \
                    operand.mem.base == X86_REG_RIP:
                target_va = instruction.address + instruction.size + \
                    operand.mem.disp
                target_rva = target_va - image_base
                value = string_literals.get(target_rva)
                if value is not None:
                    rip_targets.append(
                        f"string_rva=0x{target_rva:x} {value!r}")
        if rip_targets:
            annotation += " ; " + ", ".join(rip_targets)
        print(
            f"0x{instruction.address:x}: "
            f"{instruction.mnemonic:<8} {instruction.op_str}{annotation}"
        )


if __name__ == "__main__":
    main()
