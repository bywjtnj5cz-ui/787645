#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ARWorld Xcode 工程生成器
用法: python3 Scripts/gen_xcodeproj.py
会自动扫描 ARWorld/ 源码目录，生成/重建 ARWorld.xcodeproj

设计要点（对齐现有手写 project.pbxproj）:
  * 仅 Swift 源码 (ARWorldApp / ARController / HUDOverlay)
  * 无 ObjC / C 源码、无 Bridging Header、无 Exploits 目录
  * 无额外 OTHER_LDFLAGS (ARKit/Vision/RealityKit 均由 Swift module 自动链接)
  * 使用显式 Info.plist (GENERATE_INFOPLIST_FILE = NO)
  * 产物 .app 名 = ARWorld.app, Bundle ID = com.arworld.app
"""
import os
import uuid
from pathlib import Path

# 工程根目录
ROOT = Path(__file__).resolve().parent.parent
PROJECT_NAME = "ARWorld"
BUNDLE_ID = "com.arworld.app"
APP_DISPLAY_NAME = "ARWorld"
IOS_DEPLOYMENT_TARGET = "15.0"

# 生成唯一 ID（24位十六进制）
def gen_id():
    return uuid.uuid4().hex[:24].upper()

def collect_files(directory, extensions):
    """收集目录下指定扩展名的文件（递归，跳过隐藏目录/文件）"""
    files = []
    for root, dirs, filenames in os.walk(directory):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for f in filenames:
            if f.endswith(extensions) and not f.startswith('.'):
                files.append(os.path.join(root, f))
    return sorted(files)

def write_file(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

def generate_scheme(target_id):
    """生成共享 scheme, 供 xcodebuild -scheme ARWorld / GitHub Actions 使用
    BlueprintIdentifier 必须与 pbxproj 中的 target_id 一致"""
    scheme_dir = ROOT / f"{PROJECT_NAME}.xcodeproj" / "xcshareddata" / "xcschemes"
    scheme_path = scheme_dir / f"{PROJECT_NAME}.xcscheme"
    content = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{PROJECT_NAME}.app"
               BlueprintName = "{PROJECT_NAME}"
               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{PROJECT_NAME}.app"
            BlueprintName = "{PROJECT_NAME}"
            ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{PROJECT_NAME}.app"
            BlueprintName = "{PROJECT_NAME}"
            ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
    write_file(scheme_path, content)
    return scheme_path

def main():
    print(f"[*] 生成 {PROJECT_NAME}.xcodeproj ...")

    # 收集 Swift 源码 (仅 ARWorld/ 目录, 无 Exploits)
    swift_sources = collect_files(ROOT / PROJECT_NAME, '.swift')

    # 资源文件: Assets.xcassets 作为资源编译, Info.plist 作为 plist 引用
    assets_catalog = ROOT / PROJECT_NAME / "Assets.xcassets"
    info_plist = ROOT / PROJECT_NAME / "Info.plist"
    resources = [str(assets_catalog)] if assets_catalog.exists() else []

    print(f"    Swift 源码: {len(swift_sources)} 个")
    print(f"    资源目录: {len(resources)} 个")

    # 生成 pbxproj 内容 (返回 target_id 供 scheme 使用)
    pbxproj, target_id = generate_pbxproj(swift_sources, resources)

    # 写入 xcodeproj
    proj_dir = ROOT / f"{PROJECT_NAME}.xcodeproj"
    proj_dir.mkdir(exist_ok=True)
    write_file(proj_dir / "project.pbxproj", pbxproj)

    # 生成共享 scheme (xcodebuild -scheme ARWorld 依赖它)
    scheme_path = generate_scheme(target_id)

    print(f"[✓] 工程已生成: {proj_dir}")
    print(f"[✓] 共享 scheme 已生成: {scheme_path}")

def generate_pbxproj(swift_sources, resources):
    # 各个 section 的 ID
    proj_id = gen_id()
    target_id = gen_id()
    main_group_id = gen_id()
    sources_group_id = gen_id()
    products_group_id = gen_id()
    build_phase_sources_id = gen_id()
    build_phase_resources_id = gen_id()
    build_phase_frameworks_id = gen_id()
    config_list_proj_id = gen_id()
    config_list_target_id = gen_id()
    config_debug_proj_id = gen_id()
    config_release_proj_id = gen_id()
    config_debug_target_id = gen_id()
    config_release_target_id = gen_id()
    product_ref_id = gen_id()

    # 所有文件的 FileReference ID
    file_refs = {}
    for src in swift_sources:
        file_refs[src] = gen_id()
    for res in resources:
        file_refs[res] = gen_id()
    info_plist_id = gen_id()
    file_refs['Info.plist'] = info_plist_id

    lines = []
    lines.append("// !$*UTF8*$!")
    lines.append("{")
    lines.append("\tarchiveVersion = 1;")
    lines.append("\tclasses = {")
    lines.append("\t};")
    lines.append("\tobjectVersion = 56;")
    lines.append("\tobjects = {")
    lines.append("")

    # PBXBuildFile section
    lines.append("/* Begin PBXBuildFile section */")
    build_files = {}
    for src in swift_sources:
        bid = gen_id()
        build_files[src] = bid
        lines.append(f"\t\t{bid} /* {os.path.basename(src)} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[src]} /* {os.path.basename(src)} */; }};")
    for res in resources:
        bid = gen_id()
        build_files[res] = bid
        lines.append(f"\t\t{bid} /* {os.path.basename(res)} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_refs[res]} /* {os.path.basename(res)} */; }};")
    lines.append("/* End PBXBuildFile section */")
    lines.append("")

    # PBXFileReference section
    lines.append("/* Begin PBXFileReference section */")
    for src in swift_sources:
        fid = file_refs[src]
        p = os.path.basename(src)
        lines.append(f"\t\t{fid} /* {os.path.basename(src)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"{p}\"; sourceTree = \"<group>\"; }};")
    for res in resources:
        fid = file_refs[res]
        ext = os.path.splitext(res)[1]
        ftype = 'folder.assetcatalog' if res.endswith('.xcassets') else 'text'
        lines.append(f"\t\t{fid} /* {os.path.basename(res)} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = \"{os.path.basename(res)}\"; sourceTree = \"<group>\"; }};")
    # Info.plist
    lines.append(f"\t\t{info_plist_id} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
    # Product
    lines.append(f"\t\t{product_ref_id} /* {PROJECT_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {PROJECT_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    lines.append("/* End PBXFileReference section */")
    lines.append("")

    # PBXFrameworksBuildPhase section
    lines.append("/* Begin PBXFrameworksBuildPhase section */")
    lines.append(f"\t\t{build_phase_frameworks_id} /* Frameworks */ = {{")
    lines.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.append("/* End PBXFrameworksBuildPhase section */")
    lines.append("")

    # PBXGroup section
    lines.append("/* Begin PBXGroup section */")
    # 主 group
    lines.append(f"\t\t{main_group_id} = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    lines.append(f"\t\t\t\t{sources_group_id} /* {PROJECT_NAME} */,")
    lines.append(f"\t\t\t\t{products_group_id} /* Products */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

    # ARWorld 源码 group (含 Swift 源码 + Info.plist + Assets.xcassets)
    lines.append(f"\t\t{sources_group_id} /* {PROJECT_NAME} */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    for src in swift_sources:
        lines.append(f"\t\t\t\t{file_refs[src]} /* {os.path.basename(src)} */,")
    lines.append(f"\t\t\t\t{info_plist_id} /* Info.plist */,")
    for res in resources:
        lines.append(f"\t\t\t\t{file_refs[res]} /* {os.path.basename(res)} */,")
    lines.append("\t\t\t);")
    lines.append(f"\t\t\tpath = {PROJECT_NAME};")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

    # Products group
    lines.append(f"\t\t{products_group_id} /* Products */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    lines.append(f"\t\t\t\t{product_ref_id} /* {PROJECT_NAME}.app */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = Products;")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")
    lines.append("/* End PBXGroup section */")
    lines.append("")

    # PBXNativeTarget section
    lines.append("/* Begin PBXNativeTarget section */")
    lines.append(f"\t\t{target_id} /* {PROJECT_NAME} */ = {{")
    lines.append("\t\t\tisa = PBXNativeTarget;")
    lines.append(f"\t\t\tbuildConfigurationList = {config_list_target_id} /* Build configuration list for PBXNativeTarget \"{PROJECT_NAME}\" */;")
    lines.append("\t\t\tbuildPhases = (")
    lines.append(f"\t\t\t\t{build_phase_sources_id} /* Sources */,")
    lines.append(f"\t\t\t\t{build_phase_frameworks_id} /* Frameworks */,")
    lines.append(f"\t\t\t\t{build_phase_resources_id} /* Resources */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tbuildRules = (")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdependencies = (")
    lines.append("\t\t\t);")
    lines.append(f"\t\t\tname = {PROJECT_NAME};")
    lines.append(f"\t\t\tproductName = {PROJECT_NAME};")
    lines.append(f"\t\t\tproductReference = {product_ref_id} /* {PROJECT_NAME}.app */;")
    lines.append("\t\t\tproductType = \"com.apple.product-type.application\";")
    lines.append("\t\t};")
    lines.append("/* End PBXNativeTarget section */")
    lines.append("")

    # PBXProject section
    lines.append("/* Begin PBXProject section */")
    lines.append(f"\t\t{proj_id} /* Project object */ = {{")
    lines.append("\t\t\tisa = PBXProject;")
    lines.append("\t\t\tattributes = {")
    lines.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    lines.append("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    lines.append("\t\t\t\tLastUpgradeCheck = 1500;")
    lines.append("\t\t\t\tTargetAttributes = {")
    lines.append(f"\t\t\t\t\t{target_id} = {{")
    lines.append("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    lines.append("\t\t\t\t\t};")
    lines.append("\t\t\t\t};")
    lines.append("\t\t\t};")
    lines.append(f"\t\t\tbuildConfigurationList = {config_list_proj_id} /* Build configuration list for PBXProject \"{PROJECT_NAME}\" */;")
    lines.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    lines.append("\t\t\tdevelopmentRegion = en;")
    lines.append("\t\t\thasScannedForEncodings = 0;")
    lines.append("\t\t\tknownRegions = (")
    lines.append("\t\t\t\ten,")
    lines.append("\t\t\t\tBase,")
    lines.append("\t\t\t);")
    lines.append(f"\t\t\tmainGroup = {main_group_id};")
    lines.append(f"\t\t\tproductRefGroup = {products_group_id} /* Products */;")
    lines.append("\t\t\tprojectDirPath = \"\";")
    lines.append("\t\t\tprojectRoot = \"\";")
    lines.append("\t\t\ttargets = (")
    lines.append(f"\t\t\t\t{target_id} /* {PROJECT_NAME} */,")
    lines.append("\t\t\t);")
    lines.append("\t\t};")
    lines.append("/* End PBXProject section */")
    lines.append("")

    # PBXResourcesBuildPhase section
    lines.append("/* Begin PBXResourcesBuildPhase section */")
    lines.append(f"\t\t{build_phase_resources_id} /* Resources */ = {{")
    lines.append("\t\t\tisa = PBXResourcesBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    for res in resources:
        lines.append(f"\t\t\t\t{build_files[res]} /* {os.path.basename(res)} in Resources */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.append("/* End PBXResourcesBuildPhase section */")
    lines.append("")

    # PBXSourcesBuildPhase section
    lines.append("/* Begin PBXSourcesBuildPhase section */")
    lines.append(f"\t\t{build_phase_sources_id} /* Sources */ = {{")
    lines.append("\t\t\tisa = PBXSourcesBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    for src in swift_sources:
        lines.append(f"\t\t\t\t{build_files[src]} /* {os.path.basename(src)} in Sources */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.append("/* End PBXSourcesBuildPhase section */")
    lines.append("")

    # XCBuildConfiguration section
    lines.append("/* Begin XCBuildConfiguration section */")
    # Project Debug
    lines.append(f"\t\t{config_debug_proj_id} /* Debug */ = {{")
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    lines.append("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
    lines.append("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
    lines.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
    lines.append("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
    lines.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
    lines.append("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
    lines.append("\t\t\t\tENABLE_TESTABILITY = YES;")
    lines.append("\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu11;")
    lines.append("\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;")
    lines.append("\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;")
    lines.append("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
    lines.append("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (")
    lines.append("\t\t\t\t\t\"DEBUG=1\",")
    lines.append("\t\t\t\t\t\"$(inherited)\",")
    lines.append("\t\t\t\t);")
    lines.append("\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;")
    lines.append("\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;")
    lines.append("\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;")
    lines.append("\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;")
    lines.append("\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;")
    lines.append("\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;")
    lines.append(f"\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = {IOS_DEPLOYMENT_TARGET};")
    lines.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;")
    lines.append("\t\t\t\tMTL_FAST_MATH = YES;")
    lines.append("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
    lines.append("\t\t\t\tSDKROOT = iphoneos;")
    lines.append("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
    lines.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
    lines.append("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
    lines.append("\t\t\t\tVERSIONING_SYSTEM = \"apple-generic\";")
    lines.append("\t\t\t\tVERSION_INFO_PREFIX = \"\";")
    lines.append("\t\t\t};")
    lines.append("\t\t\tname = Debug;")
    lines.append("\t\t};")
    # Project Release
    lines.append(f"\t\t{config_release_proj_id} /* Release */ = {{")
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    lines.append("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
    lines.append("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
    lines.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
    lines.append("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
    lines.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
    lines.append("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
    lines.append("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
    lines.append("\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu11;")
    lines.append("\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;")
    lines.append("\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;")
    lines.append("\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;")
    lines.append("\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;")
    lines.append("\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;")
    lines.append("\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;")
    lines.append("\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;")
    lines.append(f"\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = {IOS_DEPLOYMENT_TARGET};")
    lines.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;")
    lines.append("\t\t\t\tMTL_FAST_MATH = YES;")
    lines.append("\t\t\t\tSDKROOT = iphoneos;")
    lines.append("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
    lines.append("\t\t\t\tVALIDATE_PRODUCT = YES;")
    lines.append("\t\t\t};")
    lines.append("\t\t\tname = Release;")
    lines.append("\t\t};")

    # Target Debug
    lines.append(f"\t\t{config_debug_target_id} /* Debug */ = {{")
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    lines.append("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
    lines.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
    lines.append("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
    lines.append("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
    lines.append(f"\t\t\t\tINFOPLIST_FILE = {PROJECT_NAME}/Info.plist;")
    lines.append("\t\t\t\tINFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;")
    lines.append("\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;")
    lines.append("\t\t\t\tINFOPLIST_KEY_UIStatusBarHidden = YES;")
    lines.append("\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = \"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";")
    lines.append("\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = \"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";")
    lines.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
    lines.append("\t\t\t\t\t\"$(inherited)\",")
    lines.append("\t\t\t\t\t\"@executable_path/Frameworks\",")
    lines.append("\t\t\t\t);")
    lines.append("\t\t\t\tMARKETING_VERSION = 1.0;")
    lines.append(f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};")
    lines.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
    lines.append("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;")
    lines.append("\t\t\t\tSWIFT_VERSION = 5.0;")
    lines.append("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
    lines.append("\t\t\t};")
    lines.append("\t\t\tname = Debug;")
    lines.append("\t\t};")

    # Target Release
    lines.append(f"\t\t{config_release_target_id} /* Release */ = {{")
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    lines.append("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
    lines.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
    lines.append("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
    lines.append("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
    lines.append(f"\t\t\t\tINFOPLIST_FILE = {PROJECT_NAME}/Info.plist;")
    lines.append("\t\t\t\tINFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;")
    lines.append("\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;")
    lines.append("\t\t\t\tINFOPLIST_KEY_UIStatusBarHidden = YES;")
    lines.append("\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = \"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";")
    lines.append("\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = \"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";")
    lines.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
    lines.append("\t\t\t\t\t\"$(inherited)\",")
    lines.append("\t\t\t\t\t\"@executable_path/Frameworks\",")
    lines.append("\t\t\t\t);")
    lines.append("\t\t\t\tMARKETING_VERSION = 1.0;")
    lines.append(f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};")
    lines.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
    lines.append("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;")
    lines.append("\t\t\t\tSWIFT_VERSION = 5.0;")
    lines.append("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
    lines.append("\t\t\t};")
    lines.append("\t\t\tname = Release;")
    lines.append("\t\t};")
    lines.append("/* End XCBuildConfiguration section */")
    lines.append("")

    # XCConfigurationList section
    lines.append("/* Begin XCConfigurationList section */")
    lines.append(f"\t\t{config_list_proj_id} /* Build configuration list for PBXProject \"{PROJECT_NAME}\" */ = {{")
    lines.append("\t\t\tisa = XCConfigurationList;")
    lines.append("\t\t\tbuildConfigurations = (")
    lines.append(f"\t\t\t\t{config_debug_proj_id} /* Debug */,")
    lines.append(f"\t\t\t\t{config_release_proj_id} /* Release */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    lines.append("\t\t\tdefaultConfigurationName = Release;")
    lines.append("\t\t};")
    lines.append(f"\t\t{config_list_target_id} /* Build configuration list for PBXNativeTarget \"{PROJECT_NAME}\" */ = {{")
    lines.append("\t\t\tisa = XCConfigurationList;")
    lines.append("\t\t\tbuildConfigurations = (")
    lines.append(f"\t\t\t\t{config_debug_target_id} /* Debug */,")
    lines.append(f"\t\t\t\t{config_release_target_id} /* Release */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    lines.append("\t\t\tdefaultConfigurationName = Release;")
    lines.append("\t\t};")
    lines.append("/* End XCConfigurationList section */")
    lines.append("")

    lines.append("\t};")
    lines.append(f"\trootObject = {proj_id} /* Project object */;")
    lines.append("}")

    return "\n".join(lines) + "\n", target_id

if __name__ == "__main__":
    main()
