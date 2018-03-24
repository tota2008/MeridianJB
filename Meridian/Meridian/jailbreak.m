//
//  jailbreak.m
//  Meridian
//
//  Created by Ben Sparkes on 16/02/2018.
//  Copyright © 2018 Ben Sparkes. All rights reserved.
//

#include "v0rtex.h"
#include "kernel.h"
#include "helpers.h"
#include "root-rw.h"
#include "amfi.h"
#include "offsetfinder.h"
#include "jailbreak.h"
#include "ViewController.h"
#include "patchfinder64.h"
#include <mach/mach_types.h>
#include <sys/stat.h>
#import <Foundation/Foundation.h>

NSFileManager *fileMgr;

task_t tfp0;
uint64_t kslide;
uint64_t kernel_base;
uint64_t kern_ucred;
uint64_t kernprocaddr;

int makeShitHappen(ViewController *view) {
    int ret;
    
    fileMgr = [NSFileManager defaultManager];

    // run v0rtex
    [view writeText:@"running v0rtex..."];
    suspend_all_threads();
    ret = runV0rtex();
    resume_all_threads();
    if (ret != 0) {
        [view writeText:@"failed!"];
        return 1;
    }
    [view writeTextPlain:@"succeeded! praize siguza!"];
    
    // set up stuff
    init_kernel(tfp0);
    init_patchfinder(tfp0, kernel_base, NULL);
    init_amfi();
    
    // patch containermanager
    [view writeText:@"patching containermanager..."];
    ret = patchContainermanagerd();
    if (ret != 0) {
        [view writeText:@"failed!"];
        return 1;
    }
    [view writeText:@"done!"];
    
    // remount root fs
    [view writeText:@"remounting rootfs as r/w..."];
    ret = remountRootFs();
    if (ret != 0) {
        [view writeText:@"failed!"];
        return 1;
    }
    [view writeText:@"done!"];
    
    mkdir("/meridian", 0755);
    mkdir("/meridian/logs", 0755);
    ret = extract_bundle("tar.tar", "/meridian");
    if (ret != 0) {
        [view writeTextPlain:@"failed to extract tar.tar bundle! ret: %d, errno: %d", ret, errno];
        return 1;
    }
    
    chmod("/meridian/tar", 0755);
    inject_trust("/meridian/tar");
    
    if (file_exists("/meridian") != 0) {
        [view writeTextPlain:@"failed to create /meridian directory!"];
        return 1;
    }
    if (file_exists("/meridian/tar") != 0) {
        [view writeTextPlain:@"failed to extract tar binary (not found)!"];
        return 1;
    }
    
    // extract meridian-bootstrap
    [view writeText:@"extracting meridian files..."];
    ret = extractMeridianData();
    if (ret != 0) {
        [view writeText:@"failed!"];
        [view writeTextPlain:[NSString stringWithFormat:@"error code: %d", ret]];
        return 1;
    }
    [view writeText:@"done!"];
    
    // symlink /Library/MobileSubstrate/DynamicLibraries -> /usr/lib/tweaks
    setUpSymLinks();
    
    // remove Substrate's SafeMode (MobileSafety) if it's installed
    // removing from dpkg will be handled by Cydia conflicts later
    if (file_exists("/usr/lib/tweaks/MobileSafety.dylib") == 0) {
        unlink("/usr/lib/tweaks/MobileSafety.dylib");
    }
    if (file_exists("/usr/lib/tweaks/MobileSafety.plist") == 0) {
        unlink("/usr/lib/tweaks/MobileSafety.plist");
    }
    
    // extract bootstrap (if not already extracted)
    if (file_exists("/meridian/.bootstrap") != 0) {
        [view writeText:@"extracting bootstrap..."];
        ret = extractBootstrap();
        
        if (ret != 0) {
            [view writeText:@"failed!"];
            
            switch (ret) {
                case 1:
                    [view writeTextPlain:@"failed to extract system-base.tar"];
                    break;
                case 2:
                    [view writeTextPlain:@"failed to extract installer-base.tar"];
                    break;
                case 3:
                    [view writeTextPlain:@"failed to extract dpkgdb-base.tar"];
                    break;
                case 4:
                    [view writeTextPlain:@"failed to extract cydia-base.tar"];
                    break;
                case 5:
                    [view writeTextPlain:@"failed to extract optional-base.tar"];
                    break;
                case 6:
                    [view writeTextPlain:@"failed to run uicache!"];
                    break;
            }
            
            return 1;
        }
        
        [view writeText:@"done!"];
    }
    
    unlink("/meridian/tar");
    
    // touch .cydia_no_stash
    touch_file("/.cydia_no_stash");
    
    // patch amfid
    [view writeText:@"patching amfid..."];
    ret = defecateAmfi();
    if (ret != 0) {
        [view writeText:@"failed!"];
        if (ret > 0) {
            [view writeTextPlain:[NSString stringWithFormat:@"failed to patch - %d tries", ret]];
        }
        return 1;
    }
    [view writeText:@"done!"];
    
    // launch dropbear
    [view writeText:@"launching dropbear..."];
    ret = launchDropbear();
    if (ret != 0) {
        [view writeText:@"failed!"];
        return 1;
    }
    [view writeText:@"done!"];
    
    // link substitute stuff
    setUpSubstitute();
    
    // start jailbreakd
    [view writeText:@"starting jailbreakd..."];
    ret = startJailbreakd();
    if (ret != 0) {
        [view writeText:@"failed"];
        return 1;
    }
    [view writeText:@"done!"];
    
    // load launchdaemons
    [view writeText:@"loading launchdaemons..."];
    ret = loadLaunchDaemons();
    if (ret != 0) {
        [view writeText:@"failed!"];
        return 1;
    }
    [view writeText:@"done!"];
    
    return 0;
}

kern_return_t callback(task_t kern_task, kptr_t kbase, uint64_t kernucred, uint64_t kernproc_addr) {
    tfp0 = kern_task;
    kernel_base = kbase;
    kslide = kernel_base - 0xFFFFFFF007004000;
    kern_ucred = kernucred;
    kernprocaddr = kernproc_addr;

    return KERN_SUCCESS;
}

int runV0rtex() {
    offsets_t *offsets = get_offsets();
    
    if (offsets == NULL) {
        return -1;
    }
    
    int ret = v0rtex(offsets, &callback);
    
    if (ret == 0) {
        NSLog(@"tfp0: 0x%x", tfp0);
        NSLog(@"kernel_base: 0x%llx", kernel_base);
        NSLog(@"kslide: 0x%llx", kslide);
        NSLog(@"kern_ucred: 0x%llx", kern_ucred);
        NSLog(@"kernprocaddr: 0x%llx", kernprocaddr);
    }
    
    return ret;
}

int patchContainermanagerd() {
    uint64_t cmgr = find_proc_by_name("containermanager");
    if (cmgr == 0) {
        NSLog(@"unable to find containermanager!");
        return 1;
    }
    
    wk64(cmgr + 0x100, kern_ucred);
    return 0;
}

int remountRootFs() {
    NSOperatingSystemVersion osVersion = [[NSProcessInfo processInfo] operatingSystemVersion];
    int pre130 = osVersion.minorVersion < 3 ? 1 : 0;
    
    int rv = mount_root(kslide, pre130);
    if (rv != 0) {
        return 1;
    }
    
    return 0;
}

int extractMeridianData() {
    return extract_bundle_tar("meridian-bootstrap.tar");
}

void setUpSymLinks() {
    struct stat file;
    stat("/Library/MobileSubstrate/DynamicLibraries", &file);
    
    if (file_exists("/usr/lib/tweaks") == 0 &&
        S_ISLNK(file.st_mode) == 0) {
        return;
    }
    
    // By the end of this check, /usr/lib/tweaks should exist containing any
    // tweaks (if applicable), and /Lib/MobSub/DynLib should NOT exist
    if (file_exists("/Library/MobileSubstrate/DynamicLibraries") == 0 &&
        file_exists("/usr/lib/tweaks") != 0) {
        // Move existing tweaks folder to /usr/lib/tweaks
        [fileMgr moveItemAtPath:@"/Library/MobileSubstrate/DynamicLibraries" toPath:@"/usr/lib/tweaks" error:nil];
    } else if (file_exists("/Library/MobileSubstrate/DynamicLibraries") == 0 &&
               file_exists("/usr/lib/tweaks") == 0) {
        // Move existing tweaks to /usr/lib/tweaks and delete the MobSub folder
        NSArray *fileList = [fileMgr contentsOfDirectoryAtPath:@"/Library/MobileSubstrate/DynamicLibraries" error:nil];
        for (NSString *item in fileList) {
            NSString *fullPath = [NSString stringWithFormat:@"/Library/MobileSubstrate/DynamicLibraries/%@", item];
            [fileMgr moveItemAtPath:fullPath toPath:@"/usr/lib/tweaks" error:nil];
        }
        [fileMgr removeItemAtPath:@"/Library/MobileSubstrate/DynamicLibraries" error:nil];
    } else if (file_exists("/Library/MobileSubstrate/DynamicLibraries") != 0 &&
               file_exists("/usr/lib/tweaks") != 0) {
        // Just create /usr/lib/tweaks - /Lib/MobSub/DynLibs doesn't exist
        mkdir("/usr/lib/tweaks", 0755);
    } else if (file_exists("/Library/MobileSubstrate/DynamicLibraries") != 0 &&
               file_exists("/usr/lib/tweaks") == 0) {
        // We should be fine in this case
    }
    
    // Symlink it!
    symlink("/usr/lib/tweaks", "/Library/MobileSubstrate/DynamicLibraries");
}

int extractBootstrap() {
    int rv;
    
    // extract system-base.tar
    rv = extract_bundle_tar("system-base.tar");
    if (rv != 0) return 1;
    
    // extract installer-base.tar
    rv = extract_bundle_tar("installer-base.tar");
    if (rv != 0) return 2;
    
    // set up dpkg database
    // if dpkg is already installed (previously jailbroken), we want to move the database
    // over to the new location, rather than replacing it. this allows users to retain
    // tweaks and installed package information
    if (file_exists("/private/var/lib/dpkg/status") == 0) { // if pre-existing db, move to /Library
        [fileMgr moveItemAtPath:@"/private/var/lib/dpkg" toPath:@"/Library/dpkg" error:nil];
    } else if (file_exists("/Library/dpkg/status") != 0) { // doubly ensure Meridian db doesn't exist before overwriting
        rv = extract_bundle_tar("dpkgdb-base.tar"); // extract new db to /Library
        if (rv != 0) return 3;
    }
    [fileMgr removeItemAtPath:@"/private/var/lib/dpkg" error:nil]; // remove old /var folder if exists for any reason
    symlink("/Library/dpkg", "/private/var/lib/dpkg"); // symlink vanilla folder to new /Library install
    
    // extract cydia-base.tar
    rv = extract_bundle_tar("cydia-base.tar");
    if (rv != 0) return 4;
    
    // extract optional-base.tar
    rv = extract_bundle_tar("optional-base.tar");
    if (rv != 0) return 5;
    
    inject_trust("/usr/bin/killall");
    enableHiddenApps();
    
    touch_file("/meridian/.bootstrap");
    unlink("/meridian/tar");
    
    inject_trust("/bin/uicache");
    rv = uicache();
    if (rv != 0) return 6;
    
    return 0;
}

int defecateAmfi() {
    // write kslide to file
    unlink("/meridian/kernel_slide");
    FILE *fd = fopen("/meridian/kernel_slide", "w");
    fprintf(fd, "%016llx", kslide);
    fclose(fd);
    
    // trust our payload
    inject_trust("/meridian/amfid_payload.dylib");
    
    unlink("/var/tmp/amfid_payload.alive");
    
    pid_t pid = get_pid_for_name("amfid");
    if (pid == 0) {
        return -1;
    }
    
    inject_library(pid, "/meridian/amfid_payload.dylib");
    
    int tries = 0;
    while (file_exists("/var/tmp/amfid_payload.alive") != 0) {
        if (tries >= 100) {
            NSLog(@"failed to patch amfid (%d tries)", tries);
            return tries;
        }
        
        NSLog(@"waiting for amfid patch...");
        usleep(100000); // 0.1 sec
        tries++;
    }
    
    return 0;
}

int launchDropbear() {
    inject_trust("/bin/launchctl");
    
    return start_launchdaemon("/meridian/dropbear/dropbear.plist");
}

void setUpSubstitute() {
    // create /Library/MobileSubstrate/DynamicLibraries
    if (file_exists("/Library/MobileSubstrate/DynamicLibraries") == 0) {
        mkdir("/Library/MobileSubstrate", 0755);
        mkdir("/Library/MobileSubstrate/DynamicLibraries", 0755);
    }
    
    // link CydiaSubstrate.framework -> /usr/lib/libsubstrate.dylib
    if (file_exists("/Library/Frameworks/CydiaSubstrate.framework") == 0) {
        [fileMgr removeItemAtPath:@"/Library/Frameworks/CydiaSubstrate.framework" error:nil];
    }
    mkdir("/Library/Frameworks", 0755);
    mkdir("/Library/Frameworks/CydiaSubstrate.framework", 0755);
    symlink("/usr/lib/libsubstrate.dylib", "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate");
}

int startJailbreakd() {
    unlink("/var/tmp/jailbreakd.pid");
    
    NSData *blob = [NSData dataWithContentsOfFile:@"/meridian/jailbreakd/jailbreakd.plist"];
    NSMutableDictionary *job = [NSPropertyListSerialization propertyListWithData:blob options:NSPropertyListMutableContainers format:nil error:nil];
    
    job[@"EnvironmentVariables"][@"KernelBase"] = [NSString stringWithFormat:@"0x%16llx", kernel_base];
    job[@"EnvironmentVariables"][@"KernProcAddr"] = [NSString stringWithFormat:@"0x%16llx", kernprocaddr];
    job[@"EnvironmentVariables"][@"ZoneMapOffset"] = [NSString stringWithFormat:@"0x%16llx", get_offset_zonemap()];
    [job writeToFile:@"/meridian/jailbreakd/jailbreakd.plist" atomically:YES];
    chmod("/meridian/jailbreakd/jailbreakd.plist", 0600);
    chown("/meridian/jailbreakd/jailbreakd.plist", 0, 0);
    
    int rv = start_launchdaemon("/meridian/jailbreakd/jailbreakd.plist");
    if (rv != 0) return 1;
    
    while (file_exists("/var/tmp/jailbreakd.pid") != 0) {
        printf("Waiting for jailbreakd \n");
        usleep(300000); // 300ms
    }
    
    // tell jailbreakd to platformize launchd
    // this adds skip-lib-val to MACF slot and allows us
    // to inject pspawn without it being in trust cache
    // (FAT/multiarch in trust cache is a pain to code, i'm lazy)
    rv = call_jailbreakd(JAILBREAKD_COMMAND_ENTITLE, 1);
    if (rv != 0) return 2;
    
    // inject pspawn_hook.dylib to launchd
    rv = inject_library(1, "/usr/lib/pspawn_hook.dylib");
    if (rv != 0) return 3;
    
    return 0;
}

int loadLaunchDaemons() {
    NSArray *daemons = [fileMgr contentsOfDirectoryAtPath:@"/Library/LaunchDaemons" error:nil];
    for (NSString *file in daemons) {
        NSString *path = [NSString stringWithFormat:@"/Library/LaunchDaemons/%@", file];
        NSLog(@"found launchdaemon: %@", path);
        chmod([path UTF8String], 0755);
        chown([path UTF8String], 0, 0);
    }
    
    return start_launchdaemon("/Library/LaunchDaemons");
}

void enableHiddenApps() {
    // enable showing of system apps on springboard
    // this is some funky killall stuff tho
    killall("cfprefsd", "-SIGSTOP");
    NSMutableDictionary* md = [[NSMutableDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/Preferences/com.apple.springboard.plist"];
    [md setObject:[NSNumber numberWithBool:YES] forKey:@"SBShowNonDefaultSystemApps"];
    [md writeToFile:@"/var/mobile/Library/Preferences/com.apple.springboard.plist" atomically:YES];
    killall("cfprefsd", "-9");
}
