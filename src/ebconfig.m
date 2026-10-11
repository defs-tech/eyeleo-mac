#import "ebconfig.h"

#import "ebcore.h"

#include <pwd.h>
#include <unistd.h>

// The container path the app used before ~/.config, kept only so the migration can find the files there.
static NSString *LegacyDirectory(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)
                            .firstObject;
    return [support stringByAppendingPathComponent:@"EyeLeo"];
}

// The user's own home directory, not the one this process sees.
//
// Inside the sandbox NSHomeDirectory() reports the container, so a path built from it lands back inside
// the container and the move we wanted is undone by the move itself. The passwd entry is the one answer
// that is not a variable the sandbox sets. NSHomeDirectory is kept as a fallback for the one case where
// there is no passwd entry to ask.
static NSString *UserHomeDirectory(void) {
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir && *pw->pw_dir)
        return @(pw->pw_dir);
    return NSHomeDirectory();
}

NSString *EBConfigDirectory(void) {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *config = [UserHomeDirectory() stringByAppendingPathComponent:@".config"];
        directory = [config stringByAppendingPathComponent:@"eyeleo-mac"];
    });
    return directory;
}

NSString *EBTeaConfigPath(void) {
    return [EBConfigDirectory() stringByAppendingPathComponent:@"tea.conf"];
}

NSString *EBSettingsPath(void) {
    return [EBConfigDirectory() stringByAppendingPathComponent:@"settings.xml"];
}

NSString *EBSettingsPathForDomain(NSString *domain) {
    if (!domain)
        return EBSettingsPath();
    // The temporary directory rather than ~/.config: a test run has no business leaving anything in the
    // place the user keeps their settings, however it is told where to look.
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
                       [domain stringByAppendingPathComponent:@"settings.xml"]];
}

NSDictionary *EBReadSettings(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data)
        return nil;
    id root = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    return [root isKindOfClass:NSDictionary.class] ? root : nil;
}

BOOL EBWriteSettings(NSString *path, NSDictionary *settings) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:settings
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data) {
        if (EBTraceOn())
            fprintf(stderr, "[EB] settings could not be encoded: %s\n", error.localizedDescription.UTF8String);
        return NO;
    }
    // writeToFile:atomically: writes to a temporary file and renames it, which fails outright if the
    // directory is not there yet rather than creating it. The real directory is made by the migration and
    // by the seeding; a caller with a path of its own, as the tests have, would otherwise get a silent
    // failure and settings that never persist.
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager fileExistsAtPath:directory] &&
        ![NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL])
        return NO;

    return [data writeToFile:path atomically:YES];
}

// One file copied from the container to the new directory, leaving anything already there alone.
static BOOL MoveOneFile(NSString *from, NSString *to) {
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:from] || [files fileExistsAtPath:to])
        return NO;
    if (![files createDirectoryAtPath:to.stringByDeletingLastPathComponent
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:NULL])
        return NO;
    return [files copyItemAtPath:from toPath:to error:NULL];
}

// The settings did not live in a file of their own before: cfprefsd kept them under the key "eyeleo" in
// the app's preferences domain. Reading that plist and taking the one key out of it is the whole of the
// move for them.
static BOOL MoveLegacySettings(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *prefs = [[LegacyDirectory() stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"Preferences/local.eyeleo.EyeLeo.plist"];
    if ([files fileExistsAtPath:EBSettingsPath()] || ![files fileExistsAtPath:prefs])
        return NO;

    NSData *data = [NSData dataWithContentsOfFile:prefs];
    if (!data)
        return NO;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    NSDictionary *stored = [plist isKindOfClass:NSDictionary.class] ? plist[@"eyeleo"] : nil;
    if (![stored isKindOfClass:NSDictionary.class])
        return NO;

    BOOL ok = EBWriteSettings(EBSettingsPath(), stored);
    if (ok && EBTraceOn())
        fprintf(stderr, "[EB] settings moved out of the sandbox container to %s\n",
                EBSettingsPath().UTF8String);
    return ok;
}

void EBMigrateLegacyConfig(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:EBConfigDirectory()] &&
        ![files createDirectoryAtPath:EBConfigDirectory() withIntermediateDirectories:YES attributes:nil error:NULL])
        return;

    MoveLegacySettings();
    MoveOneFile([LegacyDirectory() stringByAppendingPathComponent:@"tea.conf"], EBTeaConfigPath());
}