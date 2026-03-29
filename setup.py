from setuptools import setup

APP = ['groqtalk.py']
DATA_FILES = []
OPTIONS = {
    'argv_emulation': False,
    'iconfile': 'icon.icns',
    'plist': {
        'CFBundleName': 'GroqTalk',
        'CFBundleDisplayName': 'GroqTalk',
        'CFBundleIdentifier': 'com.groqtalk.app',
        'CFBundleVersion': '2.0.0',
        'CFBundleShortVersionString': '2.0.0',
        'LSBackgroundOnly': False,
        'LSUIElement': True,
        'NSMicrophoneUsageDescription': 'GroqTalk needs microphone access for voice-to-text.',
        'NSAppleEventsUsageDescription': 'GroqTalk needs this to paste text and read selections.',
        'NSHighResolutionCapable': True,
    },
    'packages': [
        'groqtalk', 'sounddevice', 'soundfile', 'numpy', 'groq',
        'httpx', 'httpcore', 'h11', 'anyio', 'sniffio', 'certifi',
        'idna', 'pydantic', 'pydantic_core', 'annotated_types',
        'dotenv', 'typing_extensions', 'distro', 'typing_inspection',
    ],
    'includes': [
        'AppKit', 'AVFoundation', 'Foundation', 'ApplicationServices',
        'Quartz', 'PyObjCTools', 'PyObjCTools.AppHelper',
        'objc', 'pyobjc_framework_Cocoa',
    ],
}

setup(
    app=APP,
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
    setup_requires=['py2app'],
)
