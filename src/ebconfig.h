// Where EyeLeo keeps its files on macOS.
//
// It used to be the app's own sandbox container, which is where a sandboxed app is allowed to write and
// therefore the path the system handed out. It is a long one and not somewhere a person goes looking, and
// the two files that matter — tea.conf and the settings — are things people are meant to edit. So they now
// live in ~/.config/eyeleo-mac, which is the conventional place on Unix and is one directory to type.
//
// Getting there costs the app one sandbox exception, declared in entitlements.plist: a sandboxed app may
// write inside its container and nowhere else, and ~/.config is outside it. That is the only entitlement
// besides app-sandbox itself, and the only thing in the app that can reach outside its own directory.

#ifndef EB_CONFIG_H
#define EB_CONFIG_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ~/.config/eyeleo-mac, created if it is not there.
NSString *EBConfigDirectory(void);

// The tea schedules, in the same place as the settings.
NSString *EBTeaConfigPath(void);

// Where the settings are stored, as an XML property list. The section and key names are the ones the
// Windows build uses, so a file exported from there is readable here.
NSString *EBSettingsPath(void);

// Where they go for a named domain, or the real path when there is none. The tests give themselves a
// domain of their own so a run cannot write over the real file; this is here so they can also clean up
// after themselves without repeating the formula.
NSString *EBSettingsPathForDomain(NSString *_Nullable domain);

// Reads the settings from a path, or nil when there are none there yet.
NSDictionary *_Nullable EBReadSettings(NSString *path);

// Writes them. Returns whether it worked, because a settings window that silently did not save is worse
// than one that says so.
BOOL EBWriteSettings(NSString *path, NSDictionary *settings);

// Moves the two files out of the sandbox container, where they were before, the first time this runs.
// Best effort and entirely silent unless something goes wrong: a failed move is not a reason to refuse to
// start, it only means the settings are read from where they already are.
void EBMigrateLegacyConfig(void);

NS_ASSUME_NONNULL_END

#endif // EB_CONFIG_H