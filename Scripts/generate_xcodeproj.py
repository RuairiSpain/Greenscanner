#!/usr/bin/env python3
"""Generate the checked-in Xcode project without external dependencies."""
from __future__ import annotations
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "GreenSight"
TESTS = ROOT / "GreenSightTests"
OUT = ROOT / "GreenSight.xcodeproj" / "project.pbxproj"


def oid(label: str) -> str:
    return hashlib.sha1(label.encode()).hexdigest().upper()[:24]


def q(value: str) -> str:
    return f'"{value}"' if any(c in value for c in ' .-/"$()') else value


app_sources = sorted(p.name for p in APP.glob("*.swift"))
test_sources = sorted(p.name for p in TESTS.glob("*.swift"))
objects: list[str] = []


def add(identifier: str, body: str) -> None:
    objects.append(f"\t\t{identifier} = {{\n{body}\n\t\t}};")


# File references and build-file records.
for name in app_sources:
    add(oid("file:app:" + name), f"\t\t\tisa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(name)}; sourceTree = \"<group>\";")
    add(oid("build:app:" + name), f"\t\t\tisa = PBXBuildFile; fileRef = {oid('file:app:' + name)} /* {name} */;")
for name in test_sources:
    add(oid("file:test:" + name), f"\t\t\tisa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(name)}; sourceTree = \"<group>\";")
    add(oid("build:test:" + name), f"\t\t\tisa = PBXBuildFile; fileRef = {oid('file:test:' + name)} /* {name} */;")

add(oid("file:assets"), "\t\t\tisa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\";")
add(oid("build:assets"), f"\t\t\tisa = PBXBuildFile; fileRef = {oid('file:assets')} /* Assets.xcassets */;")
add(oid("file:plist"), "\t\t\tisa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\";")
add(oid("product:app"), "\t\t\texplicitFileType = wrapper.application; includeInIndex = 0; isa = PBXFileReference; path = GreenSight.app; sourceTree = BUILT_PRODUCTS_DIR;")
add(oid("product:tests"), "\t\t\texplicitFileType = wrapper.cfbundle; includeInIndex = 0; isa = PBXFileReference; path = GreenSightTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;")

# Groups.
app_children = [f"{oid('file:app:' + n)} /* {n} */" for n in app_sources] + [f"{oid('file:assets')} /* Assets.xcassets */", f"{oid('file:plist')} /* Info.plist */"]
test_children = [f"{oid('file:test:' + n)} /* {n} */" for n in test_sources]
add(oid("group:app"), "\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t" + ",\n\t\t\t\t".join(app_children) + ",\n\t\t\t);\n\t\t\tpath = GreenSight; sourceTree = \"<group>\";")
add(oid("group:tests"), "\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t" + ",\n\t\t\t\t".join(test_children) + ",\n\t\t\t);\n\t\t\tpath = GreenSightTests; sourceTree = \"<group>\";")
add(oid("group:products"), f"\t\t\tisa = PBXGroup; children = ( {oid('product:app')} /* GreenSight.app */, {oid('product:tests')} /* GreenSightTests.xctest */, ); name = Products; sourceTree = \"<group>\";")
add(oid("group:root"), f"\t\t\tisa = PBXGroup; children = ( {oid('group:app')} /* GreenSight */, {oid('group:tests')} /* GreenSightTests */, {oid('group:products')} /* Products */, ); sourceTree = \"<group>\";")

# Build phases.
app_builds = ",\n\t\t\t\t".join(f"{oid('build:app:' + n)} /* {n} in Sources */" for n in app_sources)
test_builds = ",\n\t\t\t\t".join(f"{oid('build:test:' + n)} /* {n} in Sources */" for n in test_sources)
add(oid("phase:app:sources"), "\t\t\tisa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\n\t\t\t\t" + app_builds + ",\n\t\t\t); runOnlyForDeploymentPostprocessing = 0;")
add(oid("phase:test:sources"), "\t\t\tisa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\n\t\t\t\t" + test_builds + ",\n\t\t\t); runOnlyForDeploymentPostprocessing = 0;")
for label in ("app:frameworks", "test:frameworks"):
    add(oid("phase:" + label), "\t\t\tisa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
add(oid("phase:app:resources"), f"\t\t\tisa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ( {oid('build:assets')} /* Assets.xcassets in Resources */, ); runOnlyForDeploymentPostprocessing = 0;")
add(oid("phase:test:resources"), "\t\t\tisa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")

# Dependency proxy.
add(oid("proxy:test-app"), f"\t\t\tisa = PBXContainerItemProxy; containerPortal = {oid('project')} /* Project object */; proxyType = 1; remoteGlobalIDString = {oid('target:app')}; remoteInfo = GreenSight;")
add(oid("dependency:test-app"), f"\t\t\tisa = PBXTargetDependency; target = {oid('target:app')} /* GreenSight */; targetProxy = {oid('proxy:test-app')} /* PBXContainerItemProxy */;")

# Targets.
add(oid("target:app"), f"\t\t\tisa = PBXNativeTarget; buildConfigurationList = {oid('configlist:app')} /* Build configuration list for PBXNativeTarget \"GreenSight\" */; buildPhases = ( {oid('phase:app:sources')} /* Sources */, {oid('phase:app:frameworks')} /* Frameworks */, {oid('phase:app:resources')} /* Resources */, ); buildRules = (); dependencies = (); name = GreenSight; productName = GreenSight; productReference = {oid('product:app')} /* GreenSight.app */; productType = \"com.apple.product-type.application\";")
add(oid("target:tests"), f"\t\t\tisa = PBXNativeTarget; buildConfigurationList = {oid('configlist:tests')} /* Build configuration list for PBXNativeTarget \"GreenSightTests\" */; buildPhases = ( {oid('phase:test:sources')} /* Sources */, {oid('phase:test:frameworks')} /* Frameworks */, {oid('phase:test:resources')} /* Resources */, ); buildRules = (); dependencies = ( {oid('dependency:test-app')} /* PBXTargetDependency */, ); name = GreenSightTests; productName = GreenSightTests; productReference = {oid('product:tests')} /* GreenSightTests.xctest */; productType = \"com.apple.product-type.bundle.unit-test\";")

# Project.
add(oid("project"), f"\t\t\tisa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = {{ {oid('target:app')} = {{ CreatedOnToolsVersion = 16.0; }}; {oid('target:tests')} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {oid('target:app')}; }}; }}; }}; buildConfigurationList = {oid('configlist:project')} /* Build configuration list for PBXProject \"GreenSight\" */; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = ( en, Base, ); mainGroup = {oid('group:root')}; productRefGroup = {oid('group:products')} /* Products */; projectDirPath = \"\"; projectRoot = \"\"; targets = ( {oid('target:app')} /* GreenSight */, {oid('target:tests')} /* GreenSightTests */, );")

# Build configurations.
def config(label: str, settings: dict[str, str]) -> str:
    body = "\n".join(f"\t\t\t\t{k} = {v};" for k, v in settings.items())
    add(oid("config:" + label), f"\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{body}\n\t\t\t}};\n\t\t\tname = {label.split(':')[-1]};")
    return oid("config:" + label)

project_common = {
    "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17", "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "complete",
}
project_debug = project_common | {"DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0", "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"'}
project_release = project_common | {"DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"', "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": '"-O"'}
app_common = {
    "ASSETCATALOG_COMPILER_ACCENT_COLOR_NAME": "AccentColor", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "9", "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "GreenSight/Info.plist", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "MARKETING_VERSION": "1.8", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.GreenSight",
    "PRODUCT_NAME": '"$(TARGET_NAME)"', "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
    "SUPPORTS_MACCATALYST": "NO", "SWIFT_EMIT_LOC_STRINGS": "YES", "TARGETED_DEVICE_FAMILY": '"1,2"',
}
test_common = {
    "BUNDLE_LOADER": '"$(TEST_HOST)"', "CODE_SIGN_STYLE": "Automatic", "GENERATE_INFOPLIST_FILE": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.GreenSightTests",
    "PRODUCT_NAME": '"$(TARGET_NAME)"', "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": '"1,2"', "TEST_HOST": '"$(BUILT_PRODUCTS_DIR)/GreenSight.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/GreenSight"',
}
config("project:Debug", project_debug)
config("project:Release", project_release)
config("app:Debug", app_common | {"SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"'})
config("app:Release", app_common)
config("tests:Debug", test_common | {"SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"'})
config("tests:Release", test_common)

# Configuration lists.
add(oid("configlist:project"), f"\t\t\tisa = XCConfigurationList; buildConfigurations = ( {oid('config:project:Debug')} /* Debug */, {oid('config:project:Release')} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
add(oid("configlist:app"), f"\t\t\tisa = XCConfigurationList; buildConfigurations = ( {oid('config:app:Debug')} /* Debug */, {oid('config:app:Release')} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
add(oid("configlist:tests"), f"\t\t\tisa = XCConfigurationList; buildConfigurations = ( {oid('config:tests:Debug')} /* Debug */, {oid('config:tests:Release')} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

text = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n"
text += "\n".join(objects)
text += f"\n\t}};\n\trootObject = {oid('project')} /* Project object */;\n}}\n"
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(text)
print(f"generated {OUT} with {len(app_sources)} app sources and {len(test_sources)} test sources")
