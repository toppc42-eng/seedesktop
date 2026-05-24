import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart' show kCommConfKeyLang;
import 'package:flutter_hbb/models/platform_model.dart';

/// Local maintenance dashboard strings (`lm-*` keys in `src/lang/en.rs` / `he.rs`).
String lm(String key) => translate(key);

bool get lmIsHebrew =>
    bind.mainGetLocalOption(key: kCommConfKeyLang).trim() == 'he';

TextDirection get lmDir =>
    lmIsHebrew ? TextDirection.rtl : TextDirection.ltr;
