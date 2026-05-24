# -*- coding: utf-8 -*-
from lm_i18n_keys import PAIRS, rust_line, EN_RS, HE_RS

def add_missing(path, get_val):
    text = path.read_text(encoding="utf-8")
    new = []
    for he, key, en in PAIRS:
        if f'("{key}",' not in text:
            new.append(rust_line(key, get_val(he, en)))
    if not new:
        print(path.name, "all keys present")
        return
    marker = '        ("lm-external-tools-section",'
    block = "\n".join(new) + "\n"
    path.write_text(text.replace(marker, block + marker, 1), encoding="utf-8")
    print(path.name, "added", len(new))

add_missing(EN_RS, lambda he, en: en)
add_missing(HE_RS, lambda he, en: he)
