#!/usr/bin/env python3
"""Generates Hovr.xcodeproj from the files on disk (no XcodeGen or Homebrew needed).

Run again after adding or removing source files:
    python3 tools/gen_project.py
"""
import hashlib
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJ = ROOT / "Hovr.xcodeproj"
MARKETING_VERSION = "1.0"
BUILD = "1"
# Same team as the user's other apps; the updater only accepts a release signed by this team.
DEFAULT_TEAM = "WLWCRYCLRT"


def existing_team():
    """Keeps the Team chosen in Xcode when the project is regenerated."""
    pbx = PROJ / "project.pbxproj"
    if pbx.exists():
        m = re.search(r"DEVELOPMENT_TEAM = ([A-Z0-9]{10});", pbx.read_text(encoding="utf-8"))
        if m:
            return m.group(1)
    return DEFAULT_TEAM


TEAM = existing_team()


def oid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def q(s):
    s = str(s)
    if s and all(c.isalnum() or c in "._/$" for c in s):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def files(pattern):
    return sorted(p.relative_to(ROOT).as_posix() for p in ROOT.glob(pattern))


APP_SRC = files("App/**/*.swift")
APP_RES = ["App/Resources/Assets.xcassets", "App/Resources/Localizable.xcstrings"]
OTHER = ["App/Info.plist", "App/Hovr.entitlements"]

FILETYPES = {
    ".swift": "sourcecode.swift", ".xcassets": "folder.assetcatalog", ".xcstrings": "text.json.xcstrings",
    ".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements",
}

objects = {}


def add(obj_id, isa, **fields):
    objects[obj_id] = (isa, fields)
    return obj_id


file_ref = {}
for path in sorted(set(APP_SRC + APP_RES + OTHER)):
    p = pathlib.PurePosixPath(path)
    file_ref[path] = add(oid("ref", path), "PBXFileReference",
                         lastKnownFileType=FILETYPES[p.suffix], path=p.name, sourceTree="<group>")

APP_PRODUCT = add(oid("product", "app"), "PBXFileReference", explicitFileType="wrapper.application",
                  includeInIndex="0", path="Hovr.app", sourceTree="BUILT_PRODUCTS_DIR")


def group_tree():
    tree = {}
    for path in file_ref:
        node = tree
        parts = path.split("/")
        for d in parts[:-1]:
            node = node.setdefault(d, {})
        node[parts[-1]] = path

    def make(name, node, prefix):
        children = []
        for key in sorted(node, key=lambda k: (isinstance(node[k], str), k)):
            val = node[key]
            children.append(make(key, val, prefix + key + "/") if isinstance(val, dict) else file_ref[val])
        return add(oid("group", prefix), "PBXGroup", children=children, path=name, sourceTree="<group>")

    top = [make("App", tree["App"], "App/")]
    products = add(oid("group", "Products"), "PBXGroup", children=[APP_PRODUCT], name="Products", sourceTree="<group>")
    return add(oid("group", "main"), "PBXGroup", children=top + [products], sourceTree="<group>"), products


MAIN_GROUP, PRODUCTS_GROUP = group_tree()


def build_files(paths, phase):
    return [add(oid("bf", "app", phase, p), "PBXBuildFile", fileRef=file_ref[p]) for p in paths]


app_sources = add(oid("phase", "app", "src"), "PBXSourcesBuildPhase", buildActionMask="2147483647",
                  files=build_files(APP_SRC, "src"), runOnlyForDeploymentPostprocessing="0")
app_resources = add(oid("phase", "app", "res"), "PBXResourcesBuildPhase", buildActionMask="2147483647",
                    files=build_files(APP_RES, "res"), runOnlyForDeploymentPostprocessing="0")
app_frameworks = add(oid("phase", "app", "fw"), "PBXFrameworksBuildPhase", buildActionMask="2147483647",
                     files=[], runOnlyForDeploymentPostprocessing="0")

COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": BUILD,
    "DEAD_CODE_STRIPPING": "YES",
    "DEVELOPMENT_TEAM": TEAM,
    "ENABLE_HARDENED_RUNTIME": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "MARKETING_VERSION": MARKETING_VERSION,
    "SDKROOT": "macosx",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_VERSION": "5.0",
}
DEBUG = {**COMMON, "DEBUG_INFORMATION_FORMAT": "dwarf", "ONLY_ACTIVE_ARCH": "YES", "ENABLE_TESTABILITY": "YES",
         "GCC_OPTIMIZATION_LEVEL": "0", "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
         "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"}
RELEASE = {**COMMON, "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"', "SWIFT_COMPILATION_MODE": "wholemodule",
           "SWIFT_OPTIMIZATION_LEVEL": '"-O"'}

APP = {
    "DEVELOPMENT_TEAM": TEAM,
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_ENTITLEMENTS": "App/Hovr.entitlements",
    "COMBINE_HIDPI_IMAGES": "YES",
    "ENABLE_APP_SANDBOX": "NO",
    "INFOPLIST_FILE": "App/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": '"@executable_path/../Frameworks"',
    "PRODUCT_BUNDLE_IDENTIFIER": "app.hovr.Hovr",
    "PRODUCT_NAME": "Hovr",
}


def config_list(name, base_debug, base_release, extra):
    d = add(oid("cfg", name, "Debug"), "XCBuildConfiguration", buildSettings=dict(extra) if extra else base_debug, name="Debug")
    r = add(oid("cfg", name, "Release"), "XCBuildConfiguration", buildSettings=dict(extra) if extra else base_release, name="Release")
    return add(oid("cfglist", name), "XCConfigurationList", buildConfigurations=[d, r],
               defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


project_cfg = config_list("project", DEBUG, RELEASE, None)
app_cfg = config_list("app", None, None, APP)

APP_TARGET = oid("target", "app")
PROJECT = oid("project")
add(APP_TARGET, "PBXNativeTarget", buildConfigurationList=app_cfg,
    buildPhases=[app_sources, app_frameworks, app_resources], buildRules=[], dependencies=[],
    name="Hovr", productName="Hovr", productReference=APP_PRODUCT,
    productType='"com.apple.product-type.application"')
add(PROJECT, "PBXProject",
    attributes="{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; }",
    buildConfigurationList=project_cfg, compatibilityVersion='"Xcode 14.0"', developmentRegion="en",
    hasScannedForEncodings="0", knownRegions=["en", '"pt-BR"', "Base"], mainGroup=MAIN_GROUP,
    productRefGroup=PRODUCTS_GROUP, projectDirPath='""', projectRoot='""', targets=[APP_TARGET])


def value(v, indent):
    pad = "\t" * indent
    if isinstance(v, list):
        if not v:
            return "(\n" + pad + ")"
        return "(\n" + "".join(f"{pad}\t{value(x, indent + 1)},\n" for x in v) + pad + ")"
    if isinstance(v, dict):
        return "{\n" + "".join(f"{pad}\t{k} = {value(v[k], indent + 1)};\n" for k in sorted(v)) + pad + "}"
    s = str(v)
    return s if s.startswith(('"', "{")) else q(s)


out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 60;", "\tobjects = {"]
for isa in sorted({isa for isa, _ in objects.values()}):
    out.append(f"\n/* Begin {isa} section */")
    for obj_id in sorted(k for k, (i, _) in objects.items() if i == isa):
        _, fields = objects[obj_id]
        body = "".join(f"\t\t\t{k} = {value(fields[k], 3)};\n" for k in sorted(fields))
        out.append(f"\t\t{obj_id} = {{\n\t\t\tisa = {isa};\n{body}\t\t}};")
    out.append(f"/* End {isa} section */")
out += ["\t};", f"\trootObject = {PROJECT};", "}", ""]

PROJ.mkdir(exist_ok=True)
(PROJ / "project.pbxproj").write_text("\n".join(out), encoding="utf-8")
print(f"wrote {PROJ / 'project.pbxproj'}  ({len(objects)} objects, {len(APP_SRC)} sources)")
