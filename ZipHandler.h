#import <Foundation/Foundation.h>

BOOL isArchivePack(NSString* packPath);

NSData* readFileFromZip(NSString* zipPath, NSString* relativePath);

NSString* extractFileFromZip(NSString* zipPath, NSString* relativePath);