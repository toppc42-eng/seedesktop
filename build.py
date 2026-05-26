#!/usr/bin/env python3

import os
import pathlib
import platform
import zipfile
import urllib.request
import shutil
import hashlib
import argparse
import sys
from pathlib import Path

windows = platform.platform().startswith('Windows')
osx = platform.platform().startswith(
    'Darwin') or platform.platform().startswith("macOS")
hbb_name = 'rustdesk' + ('.exe' if windows else '')
exe_path = 'target/release/' + hbb_name
if windows:
    flutter_build_dir = 'build/windows/x64/runner/Release/'
elif osx:
    flutter_build_dir = 'build/macos/Build/Products/Release/'
else:
    flutter_build_dir = 'build/linux/x64/release/bundle/'
flutter_build_dir_2 = f'flutter/{flutter_build_dir}'
skip_cargo = False

# Flutter macOS output bundle; must match PRODUCT_NAME in flutter/macos/Runner/Configs/AppInfo.xcconfig
MACOS_FLUTTER_APP = "SeeDesktop.app"

# Linux .deb / desktop integration (SeeDesktop branding)
LINUX_PKG_NAME = "seedesktop"
LINUX_BINARY = "seedesktop"
LINUX_DISPLAY_NAME = "SeeDesktop"


def get_deb_arch() -> str:
    custom_arch = os.environ.get("DEB_ARCH")
    if custom_arch is None:
        return "amd64"
    return custom_arch

def get_deb_extra_depends() -> str:
    custom_arch = os.environ.get("DEB_ARCH")
    if custom_arch == "armhf": # for arm32v7 libsciter-gtk.so
        return ", libatomic1"
    return ""

def system2(cmd):
    exit_code = os.system(cmd)
    if exit_code != 0:
        sys.stderr.write(f"Error occurred when executing: `{cmd}`. Exiting.\n")
        sys.exit(-1)


def pip_install_req(requirements_rel: str):
    """Windows often has no `pip3`/`python3` on PATH; use the current interpreter."""
    rq = requirements_rel.replace("\\", "/")
    system2(f'"{sys.executable}" -m pip install -r {rq}')

def apply_custom_branding_windows_icons():
    branding_dir = Path("custom_branding")
    if not branding_dir.exists():
        return

    app_icon = branding_dir / "app_icon.ico"
    tray_icon = branding_dir / "new_tray.ico"

    if app_icon.exists():
        Path("flutter/windows/runner/resources").mkdir(parents=True, exist_ok=True)
        Path("flutter/assets").mkdir(parents=True, exist_ok=True)
        Path("res").mkdir(parents=True, exist_ok=True)
        shutil.copy2(app_icon, "flutter/windows/runner/resources/app_icon.ico")
        shutil.copy2(app_icon, "flutter/assets/icon.ico")
        shutil.copy2(app_icon, "res/icon.ico")

    if tray_icon.exists():
        Path("flutter/assets").mkdir(parents=True, exist_ok=True)
        Path("res").mkdir(parents=True, exist_ok=True)
        shutil.copy2(tray_icon, "flutter/assets/new_tray.ico")
        shutil.copy2(tray_icon, "flutter/assets/see-desktop-tray.ico")
        shutil.copy2(tray_icon, "res/new_tray.ico")


def apply_custom_branding_linux_icons():
    """Copy Linux menu icons into res/ when custom PNG/SVG/ICO branding exists."""
    branding_dir = Path("custom_branding")
    if not branding_dir.exists():
        return
    Path("res").mkdir(parents=True, exist_ok=True)
    app_ico = branding_dir / "app_icon.ico"
    if app_ico.exists():
        shutil.copy2(app_ico, Path("res/icon.ico"))
        Path("flutter/assets").mkdir(parents=True, exist_ok=True)
        shutil.copy2(app_ico, Path("flutter/assets/icon.ico"))
    app_png = branding_dir / "app_icon.png"
    app_svg = branding_dir / "app_icon.svg"
    if app_png.exists():
        for size in ("32x32", "64x64", "128x128", "128x128@2x"):
            shutil.copy2(app_png, Path(f"res/{size}.png"))
    if app_svg.exists():
        shutil.copy2(app_svg, Path("res/scalable.svg"))
    elif app_png.exists():
        # flat PNG fallback for scalable slot
        shutil.copy2(app_png, Path("res/scalable.svg"))


def ensure_linux_deb_icons():
    """Create res/*.png for .deb staging (CI has no local *png/*svg except tracked res/icon.ico)."""
    res = Path("res")
    res.mkdir(parents=True, exist_ok=True)
    ico = res / "icon.ico"
    stamp = res / "128x128@2x.png"
    if ico.is_file() and stamp.is_file() and ico.stat().st_mtime > stamp.stat().st_mtime:
        for name in ("32x32", "64x64", "128x128", "128x128@2x"):
            p = res / f"{name}.png"
            if p.is_file():
                p.unlink()
    if (res / "128x128@2x.png").is_file():
        return
    apply_custom_branding_linux_icons()
    if (res / "128x128@2x.png").is_file():
        return

    raster_src = None
    raster_kind = None
    for path, kind in (
        (res / "scalable.svg", "svg"),
        (Path("flutter/assets/icon.svg"), "svg"),
        (res / "icon.ico", "ico"),
        (Path("flutter/assets/icon.ico"), "ico"),
    ):
        if path.is_file():
            raster_src = path
            raster_kind = kind
            break

    if raster_src is None:
        sys.stderr.write(
            "Missing Linux .deb icons: add custom_branding/app_icon.png, "
            "res/scalable.svg, or res/icon.ico\n"
        )
        sys.exit(-1)

    if not (res / "scalable.svg").is_file() and raster_kind == "svg":
        shutil.copy2(raster_src, res / "scalable.svg")

    for name, px in (
        ("32x32", 32),
        ("64x64", 64),
        ("128x128", 128),
        ("128x128@2x", 256),
    ):
        out = res / f"{name}.png"
        if out.is_file():
            continue
        if raster_kind == "svg":
            raster_cmds = (
                f'rsvg-convert -w {px} -h {px} "{raster_src}" -o "{out}"',
                f'convert -background none -resize {px}x{px} "{raster_src}" "{out}"',
            )
        else:
            raster_cmds = (
                f'convert -background none "{raster_src}[0]" -resize {px}x{px} "{out}"',
                f'convert -background none -resize {px}x{px} "{raster_src}" "{out}"',
            )
        ok = False
        for cmd in raster_cmds:
            if os.system(cmd) == 0 and out.is_file():
                ok = True
                break
        if not ok:
            sys.stderr.write(
                f"Failed to create {out} from {raster_src}; "
                "install librsvg2-bin and/or imagemagick on the build host.\n"
            )
            sys.exit(-1)


def apply_custom_branding_macos_icons():
    """Copy macOS AppIcon.icns from custom branding PNG when available (Darwin only)."""
    if sys.platform != "darwin":
        return
    branding_dir = Path("custom_branding")
    app_png = branding_dir / "app_icon.png"
    if not app_png.exists():
        return
    iconset = Path("build/macos_icon.iconset")
    icns_out = Path("flutter/macos/Runner/AppIcon.icns")
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True)
    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    for px, name in sizes:
        system2(f'sips -z {px} {px} "{app_png}" --out "{iconset / name}"')
    system2(f'iconutil -c icns "{iconset}" -o "{icns_out}"')
    shutil.rmtree(iconset)


def linux_deb_output_name(version: str) -> str:
    return f"SeeDesktop-{version}-{get_deb_arch()}.deb"


def stage_linux_flutter_deb(version: str, bundle_source: str):
    """Stage tmpdeb/ for a Flutter Linux bundle under usr/share/seedesktop."""
    share = f"tmpdeb/usr/share/{LINUX_PKG_NAME}"
    system2('mkdir -p tmpdeb/usr/bin/')
    system2(f'mkdir -p {share}')
    system2(f'mkdir -p tmpdeb/etc/{LINUX_PKG_NAME}/')
    system2('mkdir -p tmpdeb/etc/pam.d/')
    system2(f'mkdir -p {share}/files/systemd/')
    system2('mkdir -p tmpdeb/usr/share/icons/hicolor/256x256/apps/')
    system2('mkdir -p tmpdeb/usr/share/icons/hicolor/scalable/apps/')
    system2('mkdir -p tmpdeb/usr/share/applications/')
    system2('mkdir -p tmpdeb/usr/share/polkit-1/actions')
    system2(f'rm -f tmpdeb/usr/bin/{LINUX_BINARY}')
    system2(f'cp -r {bundle_source}/* {share}/')
    system2(
        f'cp ../res/{LINUX_PKG_NAME}.service {share}/files/systemd/')
    system2(
        f'cp ../res/128x128@2x.png tmpdeb/usr/share/icons/hicolor/256x256/apps/{LINUX_PKG_NAME}.png')
    if os.path.isfile('../res/scalable.svg'):
        system2(
            f'cp ../res/scalable.svg tmpdeb/usr/share/icons/hicolor/scalable/apps/{LINUX_PKG_NAME}.svg')
    system2(
        f'cp ../res/{LINUX_PKG_NAME}.desktop tmpdeb/usr/share/applications/{LINUX_PKG_NAME}.desktop')
    system2(
        f'cp ../res/{LINUX_PKG_NAME}-link.desktop tmpdeb/usr/share/applications/{LINUX_PKG_NAME}-link.desktop')
    system2(
        f'cp ../res/startwm.sh tmpdeb/etc/{LINUX_PKG_NAME}/')
    system2(
        f'cp ../res/xorg.conf tmpdeb/etc/{LINUX_PKG_NAME}/')
    system2(
        f'cp ../res/pam.d/rustdesk.debian tmpdeb/etc/pam.d/{LINUX_PKG_NAME}')
    system2(
        f"echo \"#!/bin/sh\" >> {share}/files/polkit && chmod a+x {share}/files/polkit")
    system2('mkdir -p tmpdeb/DEBIAN')
    generate_control_file(version)
    system2('cp -a ../res/DEBIAN/* tmpdeb/DEBIAN/')
    for maint in ('preinst', 'postinst', 'prerm', 'postrm'):
        script = Path(f'tmpdeb/DEBIAN/{maint}')
        if script.is_file():
            script.chmod(0o755)
    md5_file_folder("tmpdeb/")
    system2('dpkg-deb -b tmpdeb seedesktop.deb;')
    system2('/bin/rm -rf tmpdeb/')
    system2('/bin/rm -rf ../res/DEBIAN/control')
    os.rename('seedesktop.deb', f'../{linux_deb_output_name(version)}')


def get_version():
    with open("Cargo.toml", encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("version"):
                return line.replace("version", "").replace("=", "").replace('"', '').strip()
    return ''


def parse_rc_features(feature):
    available_features = {}
    apply_features = {}
    if not feature:
        feature = []

    def platform_check(platforms):
        if windows:
            return 'windows' in platforms
        elif osx:
            return 'osx' in platforms
        else:
            return 'linux' in platforms

    def get_all_features():
        features = []
        for (feat, feat_info) in available_features.items():
            if platform_check(feat_info['platform']):
                features.append(feat)
        return features

    if isinstance(feature, str) and feature.upper() == 'ALL':
        return get_all_features()
    elif isinstance(feature, list):
        if windows:
            # download third party is deprecated, we use github ci instead.
            # feature.append('PrivacyMode')
            pass
        for feat in feature:
            if isinstance(feat, str) and feat.upper() == 'ALL':
                return get_all_features()
            if feat in available_features:
                if platform_check(available_features[feat]['platform']):
                    apply_features[feat] = available_features[feat]
            else:
                print(f'Unrecognized feature {feat}')
        return apply_features
    else:
        raise Exception(f'Unsupported features param {feature}')


def make_parser():
    parser = argparse.ArgumentParser(description='Build script.')
    parser.add_argument(
        '-f',
        '--feature',
        dest='feature',
        metavar='N',
        type=str,
        nargs='+',
        default='',
        help='Integrate features, windows only.'
             'Available: [Not used for now]. Special value is "ALL" and empty "". Default is empty.')
    parser.add_argument('--flutter', action='store_true',
                        help='Build flutter package', default=False)
    parser.add_argument(
        '--hwcodec',
        action='store_true',
        help='Enable feature hwcodec' + (
            '' if windows or osx else ', need libva-dev.')
    )
    parser.add_argument(
        '--vram',
        action='store_true',
        help='Enable feature vram, only available on windows now.'
    )
    parser.add_argument(
        '--portable',
        action='store_true',
        help='Build windows portable'
    )
    parser.add_argument(
        '--unix-file-copy-paste',
        action='store_true',
        help='Build with unix file copy paste feature'
    )
    parser.add_argument(
        '--skip-cargo',
        action='store_true',
        help='Skip cargo build process, only flutter version + Linux supported currently'
    )
    if windows:
        parser.add_argument(
            '--skip-portable-pack',
            action='store_true',
            help='Skip packing, only flutter version + Windows supported'
        )
    parser.add_argument(
        "--package",
        type=str
    )
    if osx:
        parser.add_argument(
            '--screencapturekit',
            action='store_true',
            help='Enable feature screencapturekit'
        )
    return parser


# Generate build script for docker
#
# it assumes all build dependencies are installed in environments
# Note: do not use it in bare metal, or may break build environments
def generate_build_script_for_docker():
    with open("/tmp/build.sh", "w") as f:
        f.write('''
            #!/bin/bash
            # environment
            export CPATH="$(clang -v 2>&1 | grep "Selected GCC installation: " | cut -d' ' -f4-)/include"
            # flutter
            pushd /opt
            wget https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.0.5-stable.tar.xz
            tar -xvf flutter_linux_3.0.5-stable.tar.xz
            export PATH=`pwd`/flutter/bin:$PATH
            popd
            # flutter_rust_bridge
            dart pub global activate ffigen --version 5.0.1
            pushd /tmp && git clone https://github.com/SoLongAndThanksForAllThePizza/flutter_rust_bridge --depth=1 && popd
            pushd /tmp/flutter_rust_bridge/frb_codegen && cargo install --path . && popd
            pushd flutter && flutter pub get && popd
            ~/.cargo/bin/flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart
            # install vcpkg
            pushd /opt
            export VCPKG_ROOT=`pwd`/vcpkg
            git clone https://github.com/microsoft/vcpkg
            vcpkg/bootstrap-vcpkg.sh
            popd
            $VCPKG_ROOT/vcpkg install --x-install-root="$VCPKG_ROOT/installed"
            # build rustdesk
            ./build.py --flutter --hwcodec
        ''')
    system2("chmod +x /tmp/build.sh")
    system2("bash /tmp/build.sh")


# Downloading third party resources is deprecated.
# We can use this function in an offline build environment.
# Even in an online environment, we recommend building third-party resources yourself.
def download_extract_features(features, res_dir):
    import re

    proxy = ''

    def req(url):
        if not proxy:
            return url
        else:
            r = urllib.request.Request(url)
            r.set_proxy(proxy, 'http')
            r.set_proxy(proxy, 'https')
            return r

    for (feat, feat_info) in features.items():
        includes = feat_info['include'] if 'include' in feat_info and feat_info['include'] else []
        includes = [re.compile(p) for p in includes]
        excludes = feat_info['exclude'] if 'exclude' in feat_info and feat_info['exclude'] else []
        excludes = [re.compile(p) for p in excludes]

        print(f'{feat} download begin')
        download_filename = feat_info['zip_url'].split('/')[-1]
        checksum_md5_response = urllib.request.urlopen(
            req(feat_info['checksum_url']))
        for line in checksum_md5_response.read().decode('utf-8').splitlines():
            if line.split()[1] == download_filename:
                checksum_md5 = line.split()[0]
                filename, _headers = urllib.request.urlretrieve(feat_info['zip_url'],
                                                                download_filename)
                md5 = hashlib.md5(open(filename, 'rb').read()).hexdigest()
                if checksum_md5 != md5:
                    raise Exception(f'{feat} download failed')
                print(f'{feat} download end. extract bein')
                zip_file = zipfile.ZipFile(filename)
                zip_list = zip_file.namelist()
                for f in zip_list:
                    file_exclude = False
                    for p in excludes:
                        if p.match(f) is not None:
                            file_exclude = True
                            break
                    if file_exclude:
                        continue

                    file_include = False if includes else True
                    for p in includes:
                        if p.match(f) is not None:
                            file_include = True
                            break
                    if file_include:
                        print(f'extract file {f}')
                        zip_file.extract(f, res_dir)
                zip_file.close()
                os.remove(download_filename)
                print(f'{feat} extract end')


def external_resources(flutter, args, res_dir):
    features = parse_rc_features(args.feature)
    if not features:
        return

    print(f'Build with features {list(features.keys())}')
    if os.path.isdir(res_dir) and not os.path.islink(res_dir):
        shutil.rmtree(res_dir)
    elif os.path.exists(res_dir):
        raise Exception(f'Find file {res_dir}, not a directory')
    os.makedirs(res_dir, exist_ok=True)
    download_extract_features(features, res_dir)
    if flutter:
        os.makedirs(flutter_build_dir_2, exist_ok=True)
        for f in pathlib.Path(res_dir).iterdir():
            print(f'{f}')
            if f.is_file():
                shutil.copy2(f, flutter_build_dir_2)
            else:
                shutil.copytree(f, f'{flutter_build_dir_2}{f.stem}')


def get_features(args):
    features = ['inline'] if not args.flutter else []
    if args.hwcodec:
        features.append('hwcodec')
    if args.vram:
        features.append('vram')
    if args.flutter:
        features.append('flutter')
    if args.unix_file_copy_paste:
        features.append('unix-file-copy-paste')
    if osx:
        if args.screencapturekit:
            features.append('screencapturekit')
    print("features:", features)
    return features


def generate_control_file(version):
    control_file_path = "../res/DEBIAN/control"
    system2('/bin/rm -rf %s' % control_file_path)

    content = """Package: %s
Section: net
Priority: optional
Version: %s
Architecture: %s
Maintainer: SeeDesktop <toppc42@gmail.com>
Homepage: https://github.com/toppc42-eng/seedesktop
Depends: libgtk-3-0, libxcb-randr0, libxdo3 | libxdo4, libxfixes3, libxcb-shape0, libxcb-xfixes0, libasound2, libsystemd0, curl, libva2, libva-drm2, libva-x11-2, libgstreamer-plugins-base1.0-0, libpam0g, gstreamer1.0-pipewire%s
Recommends: libayatana-appindicator3-1
Description: SeeDesktop remote desktop software.

""" % (LINUX_PKG_NAME, version, get_deb_arch(), get_deb_extra_depends())
    file = open(control_file_path, "w")
    file.write(content)
    file.close()


def ffi_bindgen_function_refactor():
    # workaround ffigen
    system2(
        'sed -i "s/ffi.NativeFunction<ffi.Bool Function(DartPort/ffi.NativeFunction<ffi.Uint8 Function(DartPort/g" flutter/lib/generated_bridge.dart')


def build_flutter_deb(version, features):
    if not skip_cargo:
        system2(f'cargo build --features {features} --lib --release')
        ffi_bindgen_function_refactor()
    apply_custom_branding_windows_icons()
    apply_custom_branding_linux_icons()
    ensure_linux_deb_icons()
    os.chdir('flutter')
    system2('flutter build linux --release')
    stage_linux_flutter_deb(version, flutter_build_dir)
    os.chdir("..")


def build_deb_from_folder(version, binary_folder):
    apply_custom_branding_windows_icons()
    apply_custom_branding_linux_icons()
    ensure_linux_deb_icons()
    os.chdir('flutter')
    stage_linux_flutter_deb(version, f'../{binary_folder}')
    os.chdir("..")


def _macos_sign_flutter_app(app_path: str, identity: str) -> None:
    """Optional codesign when env P is set (Developer ID Application: …)."""
    macos_dir = f'{app_path}/Contents/MacOS'
    system2(
        f'codesign -s "Developer ID Application: {identity}" --force --options runtime {macos_dir}/*'
    )
    system2(
        f'codesign -s "Developer ID Application: {identity}" --force --options runtime {app_path}'
    )


def _macos_sign_dmg(dmg_path: str, identity: str) -> None:
    system2(
        f'codesign -s "Developer ID Application: {identity}" --force --options runtime {dmg_path}'
    )
    if os.environ.get('SEEDESKTOP_NOTARIZE', '').lower() in ('1', 'true', 'yes'):
        system2(
            f'rcodesign notary-submit --api-key-path ../.p12/api-key.json --staple {dmg_path}'
        )


def build_flutter_dmg(version, features):
    apply_custom_branding_macos_icons()
    if not skip_cargo:
        # set minimum osx build target, now is 10.14, which is the same as the flutter xcode project
        system2(
            f'MACOSX_DEPLOYMENT_TARGET=10.14 cargo build --features {features} --lib --bin service --release')
    # copy dylib
    system2(
        "cp target/release/liblibrustdesk.dylib target/release/librustdesk.dylib")
    os.chdir('flutter')
    system2('flutter build macos --release')
    app_path = f'./build/macos/Build/Products/Release/{MACOS_FLUTTER_APP}'
    system2(f'cp -rf ../target/release/service {app_path}/Contents/MacOS/')

    skip_dmg = os.environ.get('SEEDESKTOP_SKIP_DMG', '').lower() in ('1', 'true', 'yes')
    sign_identity = os.environ.get('P', '').strip()
    dmg_name = f'SeeDesktop-{version}-macOS.dmg'

    if not skip_dmg:
        system2('/bin/rm -f SeeDesktop*.dmg rustdesk*.dmg')
        if sign_identity:
            _macos_sign_flutter_app(app_path, sign_identity)
        system2(
            f'create-dmg --volname "SeeDesktop Installer" '
            f'--window-pos 200 120 --window-size 800 400 --icon-size 100 '
            f'--app-drop-link 600 185 --icon {MACOS_FLUTTER_APP} 200 190 '
            f'--hide-extension {MACOS_FLUTTER_APP} {dmg_name} {app_path}'
        )
        if sign_identity:
            _macos_sign_dmg(dmg_name, sign_identity)
        else:
            print('DMG built without codesign (set env P for Developer ID signing).')
        os.rename(dmg_name, f'../{dmg_name}')
        print(f'macOS DMG: ../{dmg_name}')
    else:
        print(f'macOS app bundle: {app_path} (SEEDESKTOP_SKIP_DMG=1)')

    os.chdir("..")


def build_flutter_arch_manjaro(version, features):
    if not skip_cargo:
        system2(f'cargo build --features {features} --lib --release')
    ffi_bindgen_function_refactor()
    os.chdir('flutter')
    system2('flutter build linux --release')
    system2(f'strip {flutter_build_dir}/lib/librustdesk.so')
    os.chdir('../res')
    system2('HBB=`pwd`/.. FLUTTER=1 makepkg -f')


def copy_hw_helper_to_flutter_windows():
    """Ship hw_helper.exe + LibreHardwareMonitor deps next to SeeDesktop.exe."""
    hw_proj = pathlib.Path('hw_helper/hw_helper.csproj')
    if not hw_proj.is_file():
        return
    print('Building hw_helper (LibreHardwareMonitor)...')
    system2('dotnet build hw_helper/hw_helper.csproj -c Release')
    hw_out = None
    for sub in ('net10.0-windows', 'net8.0-windows'):
        p = pathlib.Path(f'hw_helper/bin/Release/{sub}')
        if p.is_dir():
            hw_out = p
            break
    dest = pathlib.Path(flutter_build_dir_2)
    if hw_out is None:
        print('Warning: hw_helper build output not found under net10.0-windows or net8.0-windows')
        return
    for p in hw_out.iterdir():
        if p.is_file():
            shutil.copy2(p, dest / p.name)
        elif p.is_dir() and p.name == 'runtimes':
            target = dest / 'runtimes'
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(p, target)


def build_flutter_windows(version, features, skip_portable_pack):
    if not skip_cargo:
        system2(f'cargo build --features {features} --lib --release')
        if not os.path.exists("target/release/librustdesk.dll"):
            print("cargo build failed, please check rust source code.")
            exit(-1)
        system2('cargo build -p seedesktop_backup_helper --release')
    os.chdir('flutter')
    system2('flutter build windows --release')
    os.chdir('..')
    copy_hw_helper_to_flutter_windows()
    shutil.copy2('target/release/deps/dylib_virtual_display.dll',
                 flutter_build_dir_2)
    if skip_portable_pack:
        return
    os.chdir('libs/portable')
    pip_install_req('requirements.txt')
    # BINARY_NAME in flutter/windows/CMakeLists.txt (was rustdesk.exe upstream)
    flutter_win_exe = 'SeeDesktop.exe'
    system2(
        f'"{sys.executable}" ./generate.py -f ../../{flutter_build_dir_2} -o . -e ../../{flutter_build_dir_2}{flutter_win_exe}')
    os.chdir('../..')
    if os.path.exists('./rustdesk_portable.exe'):
        os.replace('./target/release/rustdesk-portable-packer.exe',
                   './rustdesk_portable.exe')
    else:
        os.rename('./target/release/rustdesk-portable-packer.exe',
                  './rustdesk_portable.exe')
    print(
        f'output location: {os.path.abspath(os.curdir)}/rustdesk_portable.exe')
    os.rename('./rustdesk_portable.exe', f'./rustdesk-{version}-install.exe')
    print(
        f'output location: {os.path.abspath(os.curdir)}/rustdesk-{version}-install.exe')


def main():
    global skip_cargo
    parser = make_parser()
    args = parser.parse_args()

    if os.path.exists(exe_path):
        os.unlink(exe_path)
    if os.path.isfile('/usr/bin/pacman'):
        system2('git checkout src/ui/common.tis')
    version = get_version()
    features = ','.join(get_features(args))
    flutter = args.flutter
    if not flutter:
        system2('python3 res/inline-sciter.py')
    print(args.skip_cargo)
    if args.skip_cargo:
        skip_cargo = True
    portable = args.portable
    package = args.package
    if package:
        build_deb_from_folder(version, package)
        return
    res_dir = 'resources'
    external_resources(flutter, args, res_dir)
    if windows:
        apply_custom_branding_windows_icons()
        # build virtual display dynamic library
        os.chdir('libs/virtual_display/dylib')
        system2('cargo build --release')
        os.chdir('../../..')

        if flutter:
            build_flutter_windows(version, features, args.skip_portable_pack)
            return
        system2('cargo build --release --features ' + features)
        # system2('upx.exe target/release/rustdesk.exe')
        system2('mv target/release/rustdesk.exe target/release/RustDesk.exe')
        pa = os.environ.get('P')
        if pa:
            # https://certera.com/kb/tutorial-guide-for-safenet-authentication-client-for-code-signing/
            system2(
                f'signtool sign /a /v /p {pa} /debug /f .\\cert.pfx /t http://timestamp.digicert.com  '
                'target\\release\\rustdesk.exe')
        else:
            print('Not signed')
        system2(
            f'cp -rf target/release/RustDesk.exe {res_dir}')
        os.chdir('libs/portable')
        system2('pip3 install -r requirements.txt')
        system2(
            f'python3 ./generate.py -f ../../{res_dir} -o . -e ../../{res_dir}/rustdesk-{version}-win7-install.exe')
        system2('mv ../../{res_dir}/rustdesk-{version}-win7-install.exe ../..')
    elif os.path.isfile('/usr/bin/pacman'):
        # pacman -S -needed base-devel
        system2("sed -i 's/pkgver=.*/pkgver=%s/g' res/PKGBUILD" % version)
        if flutter:
            build_flutter_arch_manjaro(version, features)
        else:
            system2('cargo build --release --features ' + features)
            system2('git checkout src/ui/common.tis')
            system2('strip target/release/rustdesk')
            system2('ln -s res/pacman_install && ln -s res/PKGBUILD')
            system2('HBB=`pwd` makepkg -f')
        system2('mv rustdesk-%s-0-x86_64.pkg.tar.zst rustdesk-%s-manjaro-arch.pkg.tar.zst' % (
            version, version))
        # pacman -U ./rustdesk.pkg.tar.zst
    elif os.path.isfile('/usr/bin/yum'):
        system2('cargo build --release --features ' + features)
        system2('strip target/release/rustdesk')
        system2(
            "sed -i 's/Version:    .*/Version:    %s/g' res/rpm.spec" % version)
        system2('HBB=`pwd` rpmbuild -ba res/rpm.spec')
        system2(
            'mv $HOME/rpmbuild/RPMS/x86_64/rustdesk-%s-0.x86_64.rpm ./rustdesk-%s-fedora28-centos8.rpm' % (
                version, version))
        # yum localinstall rustdesk.rpm
    elif os.path.isfile('/usr/bin/zypper'):
        system2('cargo build --release --features ' + features)
        system2('strip target/release/rustdesk')
        system2(
            "sed -i 's/Version:    .*/Version:    %s/g' res/rpm-suse.spec" % version)
        system2('HBB=`pwd` rpmbuild -ba res/rpm-suse.spec')
        system2(
            'mv $HOME/rpmbuild/RPMS/x86_64/rustdesk-%s-0.x86_64.rpm ./rustdesk-%s-suse.rpm' % (
                version, version))
        # yum localinstall rustdesk.rpm
    else:
        if flutter:
            if osx:
                build_flutter_dmg(version, features)
                pass
            else:
                apply_custom_branding_linux_icons()
                build_flutter_deb(version, features)
        else:
            system2('cargo bundle --release --features ' + features)
            if osx:
                system2(
                    'strip target/release/bundle/osx/RustDesk.app/Contents/MacOS/rustdesk')
                system2(
                    'cp libsciter.dylib target/release/bundle/osx/RustDesk.app/Contents/MacOS/')
                # https://github.com/sindresorhus/create-dmg
                system2('/bin/rm -rf *.dmg')
                pa = os.environ.get('P')
                if pa:
                    system2('''
    # buggy: rcodesign sign ... path/*, have to sign one by one
    # install rcodesign via cargo install apple-codesign
    #rcodesign sign --p12-file ~/.p12/rustdesk-developer-id.p12 --p12-password-file ~/.p12/.cert-pass --code-signature-flags runtime ./target/release/bundle/osx/RustDesk.app/Contents/MacOS/rustdesk
    #rcodesign sign --p12-file ~/.p12/rustdesk-developer-id.p12 --p12-password-file ~/.p12/.cert-pass --code-signature-flags runtime ./target/release/bundle/osx/RustDesk.app/Contents/MacOS/libsciter.dylib
    #rcodesign sign --p12-file ~/.p12/rustdesk-developer-id.p12 --p12-password-file ~/.p12/.cert-pass --code-signature-flags runtime ./target/release/bundle/osx/RustDesk.app
    # goto "Keychain Access" -> "My Certificates" for below id which starts with "Developer ID Application:"
    codesign -s "Developer ID Application: {0}" --force --options runtime  ./target/release/bundle/osx/RustDesk.app/Contents/MacOS/*
    codesign -s "Developer ID Application: {0}" --force --options runtime  ./target/release/bundle/osx/RustDesk.app
    '''.format(pa))
                system2(
                    'create-dmg "RustDesk %s.dmg" "target/release/bundle/osx/RustDesk.app"' % version)
                os.rename('RustDesk %s.dmg' %
                          version, 'rustdesk-%s.dmg' % version)
                if pa:
                    system2('''
    # https://pyoxidizer.readthedocs.io/en/apple-codesign-0.14.0/apple_codesign.html
    # https://pyoxidizer.readthedocs.io/en/stable/tugger_code_signing.html
    # https://developer.apple.com/developer-id/
    # goto xcode and login with apple id, manager certificates (Developer ID Application and/or Developer ID Installer) online there (only download and double click (install) cer file can not export p12 because no private key)
    #rcodesign sign --p12-file ~/.p12/rustdesk-developer-id.p12 --p12-password-file ~/.p12/.cert-pass --code-signature-flags runtime ./rustdesk-{1}.dmg
    codesign -s "Developer ID Application: {0}" --force --options runtime ./rustdesk-{1}.dmg
    # https://appstoreconnect.apple.com/access/api
    # https://gregoryszorc.com/docs/apple-codesign/stable/apple_codesign_getting_started.html#apple-codesign-app-store-connect-api-key
    # p8 file is generated when you generate api key (can download only once)
    rcodesign notary-submit --api-key-path ../.p12/api-key.json  --staple rustdesk-{1}.dmg
    # verify:  spctl -a -t exec -v /Applications/RustDesk.app
    '''.format(pa, version))
                else:
                    print('Not signed')
            else:
                # build deb package
                system2(
                    'mv target/release/bundle/deb/rustdesk*.deb ./rustdesk.deb')
                system2('dpkg-deb -R rustdesk.deb tmpdeb')
                system2('mkdir -p tmpdeb/usr/share/rustdesk/files/systemd/')
                system2('mkdir -p tmpdeb/usr/share/icons/hicolor/256x256/apps/')
                system2('mkdir -p tmpdeb/usr/share/icons/hicolor/scalable/apps/')
                system2(
                    'cp res/rustdesk.service tmpdeb/usr/share/rustdesk/files/systemd/')
                system2(
                    'cp res/128x128@2x.png tmpdeb/usr/share/icons/hicolor/256x256/apps/rustdesk.png')
                system2(
                    'cp res/scalable.svg tmpdeb/usr/share/icons/hicolor/scalable/apps/rustdesk.svg')
                system2(
                    'cp res/rustdesk.desktop tmpdeb/usr/share/applications/rustdesk.desktop')
                system2(
                    'cp res/rustdesk-link.desktop tmpdeb/usr/share/applications/rustdesk-link.desktop')
                os.system('mkdir -p tmpdeb/etc/rustdesk/')
                os.system('cp -a res/startwm.sh tmpdeb/etc/rustdesk/')
                os.system('mkdir -p tmpdeb/etc/X11/rustdesk/')
                os.system('cp res/xorg.conf tmpdeb/etc/X11/rustdesk/')
                os.system('cp -a DEBIAN/* tmpdeb/DEBIAN/')
                os.system('mkdir -p tmpdeb/etc/pam.d/')
                os.system('cp pam.d/rustdesk.debian tmpdeb/etc/pam.d/rustdesk')
                system2('strip tmpdeb/usr/bin/rustdesk')
                system2('mkdir -p tmpdeb/usr/share/rustdesk')
                system2('mv tmpdeb/usr/bin/rustdesk tmpdeb/usr/share/rustdesk/')
                system2('cp libsciter-gtk.so tmpdeb/usr/share/rustdesk/')
                md5_file_folder("tmpdeb/")
                system2('dpkg-deb -b tmpdeb rustdesk.deb; /bin/rm -rf tmpdeb/')
                os.rename('rustdesk.deb', 'rustdesk-%s.deb' % version)


def md5_file(fn):
    md5 = hashlib.md5(open('tmpdeb/' + fn, 'rb').read()).hexdigest()
    system2('echo "%s  /%s" >> tmpdeb/DEBIAN/md5sums' % (md5, fn))

def md5_file_folder(base_dir):
    base_path = Path(base_dir)
    for file in base_path.rglob('*'):
        if file.is_file() and 'DEBIAN' not in file.parts:
            relative_path = file.relative_to(base_path)
            md5_file(str(relative_path))


if __name__ == "__main__":
    main()
