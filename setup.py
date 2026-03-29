from setuptools import setup

APP = ['groqtalk.py']
DATA_FILES = []
OPTIONS = {
    'argv_emulation': False,
    'plist': {
        'CFBundleName': 'GroqTalk',
        'CFBundleDisplayName': 'GroqTalk',
        'CFBundleIdentifier': 'com.groqtalk.app',
        'CFBundleVersion': '1.0.0',
        'CFBundleShortVersionString': '1.0.0',
        'LSBackgroundOnly': False,
        'LSUIElement': True,  # menubar app — no dock icon
        'NSMicrophoneUsageDescription': 'GroqTalk needs microphone access for voice-to-text.',
    },
    'packages': [
        'rumps', 'sounddevice', 'soundfile', 'numpy', 'groq',
        'httpx', 'httpcore', 'h11', 'anyio', 'sniffio', 'certifi',
        'idna', 'pydantic', 'pydantic_core', 'annotated_types',
        'dotenv', 'typing_extensions', 'distro',
    ],
    'includes': [
        'AppKit', 'AVFoundation', 'Foundation', 'ApplicationServices', 'Quartz',
    ],
}

setup(
    app=APP,
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
    setup_requires=['py2app'],
)
