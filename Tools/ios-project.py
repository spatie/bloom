#!/usr/bin/env python3
"""Generate the iOS application container. Shared code remains in Swift packages."""
import pathlib
import plistlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
output = pathlib.Path(sys.argv[1]).resolve()
project = output / 'Bloom.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
objects = []

def add(key, body):
    objects.append(f'{key} = {{ {body} }};')

def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

sources = []
references = []
for index, source in enumerate(sorted((root / 'iOS/Bloom').glob('*.swift'))):
    ref, build = f'F{index:023X}', f'B{index:023X}'
    add(ref, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(source)}; sourceTree = "<absolute>";')
    add(build, f'isa = PBXBuildFile; fileRef = {ref};')
    sources.append(build)
    references.append(ref)

add('ROOT', 'isa = PBXProject; attributes = { LastUpgradeCheck = 2650; }; buildConfigurationList = PROJECTCONFIG; compatibilityVersion = "Xcode 16.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = GROUP; productRefGroup = PRODUCTS; projectDirPath = ""; projectRoot = ""; targets = (APP); packageReferences = (CLIENT, AUTH, SSH, UI, APPAUTH);')
add('GROUP', f'isa = PBXGroup; children = ({",".join(references)}, PRODUCTS); sourceTree = "<group>";')
add('PRODUCTS', 'isa = PBXGroup; children = (PRODUCT); name = Products; sourceTree = "<group>";')
add('PRODUCT', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Bloom.app; sourceTree = BUILT_PRODUCTS_DIR;')
add('APP', 'isa = PBXNativeTarget; buildConfigurationList = APPCONFIG; buildPhases = (SOURCES, FRAMEWORKS, RESOURCES); buildRules = (); dependencies = (); name = Bloom; productName = Bloom; productReference = PRODUCT; productType = "com.apple.product-type.application"; packageProductDependencies = (CLIENTPRODUCT, AUTHPRODUCT, SSHPRODUCT, UIPRODUCT, APPAUTHPRODUCT);')
add('SOURCES', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(sources)}); runOnlyForDeploymentPostprocessing = 0;')
add('FRAMEWORKS', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (CLIENTBUILD, AUTHBUILD, SSHBUILD, UIBUILD, APPAUTHBUILD); runOnlyForDeploymentPostprocessing = 0;')
for key, name in [('CLIENT', 'BloomClient'), ('AUTH', 'BloomAuthentication'), ('SSH', 'BloomSSH'), ('UI', 'BloomUI')]:
    add(key, f'isa = XCLocalSwiftPackageReference; relativePath = {quote(root / "Packages" / name)};')
    add(key + 'PRODUCT', f'isa = XCSwiftPackageProductDependency; package = {key}; productName = {name};')
    add(key + 'BUILD', f'isa = PBXBuildFile; productRef = {key}PRODUCT;')
add('PRIVACY', f'isa = PBXFileReference; lastKnownFileType = text.xml; path = {quote(root / "iOS/Resources/PrivacyInfo.xcprivacy")}; sourceTree = "<absolute>";')
add('PRIVACYBUILD', 'isa = PBXBuildFile; fileRef = PRIVACY;')
add('LICENCES', f'isa = PBXFileReference; lastKnownFileType = folder; path = {quote(output / "Licences")}; sourceTree = "<absolute>";')
add('LICENCESBUILD', 'isa = PBXBuildFile; fileRef = LICENCES;')
add('ICON', f'isa = PBXFileReference; lastKnownFileType = folder.iconcomposer; path = {quote(root / "Resources/Bloom.icon")}; sourceTree = "<absolute>";')
add('ICONBUILD', 'isa = PBXBuildFile; fileRef = ICON;')
add('RESOURCES', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (PRIVACYBUILD, LICENCESBUILD, ICONBUILD); runOnlyForDeploymentPostprocessing = 0;')
add('APPAUTH', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/openid/AppAuth-iOS.git"; requirement = { kind = exactVersion; version = 3.0.0; };')
add('APPAUTHPRODUCT', 'isa = XCSwiftPackageProductDependency; package = APPAUTH; productName = AppAuth;')
add('APPAUTHBUILD', 'isa = PBXBuildFile; productRef = APPAUTHPRODUCT;')
add('PROJECTCONFIG', 'isa = XCConfigurationList; buildConfigurations = (PROJECTDEBUG, PROJECTRELEASE); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('APPCONFIG', 'isa = XCConfigurationList; buildConfigurations = (APPDEBUG, APPRELEASE); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
for name in ['Debug', 'Release']:
    add('PROJECT' + name.upper(), f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ CLANG_ENABLE_MODULES = YES; IPHONEOS_DEPLOYMENT_TARGET = 26.0; SDKROOT = iphoneos; SWIFT_VERSION = 6.0; }};')
    settings = f'''PRODUCT_BUNDLE_IDENTIFIER = be.spatie.bloom.ios;
    PRODUCT_NAME = Bloom; ASSETCATALOG_COMPILER_APPICON_NAME = Bloom; TARGETED_DEVICE_FAMILY = "1,2";
    INFOPLIST_FILE = {quote(output / 'Info.plist')};
    CODE_SIGN_STYLE = Automatic; SWIFT_EMIT_LOC_STRINGS = YES;
    SWIFT_TREAT_WARNINGS_AS_ERRORS = YES; ENABLE_USER_SCRIPT_SANDBOXING = YES;
    CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 0.1.0;
    LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
    SWIFT_ACTIVE_COMPILATION_CONDITIONS = "{'DEBUG' if name == 'Debug' else ''}";
    SWIFT_OPTIMIZATION_LEVEL = "{'-Onone' if name == 'Debug' else '-O'}";'''
    add('APP' + name.upper(), f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ {settings} }};')
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n' + '\n'.join(objects) + '\n}; rootObject = ROOT; }\n')
with (output / 'Info.plist').open('wb') as info:
    plistlib.dump({
        'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleExecutable': '$(EXECUTABLE_NAME)',
        'CFBundleName': 'Bloom', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '$(MARKETING_VERSION)', 'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)',
        'LSRequiresIPhoneOS': True, 'UILaunchScreen': {},
        'NSLocalNetworkUsageDescription': 'Connect to your Bloom Server on your local network.',
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': True},
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
        'CFBundleURLTypes': [{'CFBundleURLSchemes': ['be.spatie.bloom.ios']}],
    }, info)
print(project)
