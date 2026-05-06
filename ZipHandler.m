#import <zlib.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#import "ZipHandler.h"

BOOL isArchivePack(NSString* packPath) {
    NSString *ext = [packPath pathExtension].lowercaseString;
    return [ext isEqualToString:@"zip"] || [ext isEqualToString:@"mcpack"];
}

NSData* readFileFromZip(NSString* zipPath, NSString* relativePath) {
    FILE *f = fopen([zipPath UTF8String], "rb");
    if (!f) return nil;
    
    uint8_t buf[1024];
    NSData *result = nil;
    
    while (fread(buf, 1, 4, f) == 4) {
        uint32_t signature = *(uint32_t*)buf;
        
        if (signature == 0x04034b50) {
            fread(buf, 1, 26, f);
            uint16_t nameLen = *(uint16_t*)(buf + 22);
            uint16_t extraLen = *(uint16_t*)(buf + 24);
            uint32_t compSize = *(uint32_t*)(buf + 14);
            uint32_t uncompSize = *(uint32_t*)(buf + 18);
            uint16_t method = *(uint16_t*)(buf + 4);
            
            char name[512] = {0};
            if (nameLen < 512) fread(name, 1, nameLen, f);
            fseek(f, extraLen, SEEK_CUR);
            
            NSString *fileName = [NSString stringWithUTF8String:name];
            
            if ([fileName isEqualToString:relativePath]) {
                NSMutableData *data = [NSMutableData dataWithLength:uncompSize];
                void *dest = data.mutableBytes;
                
                if (method == 0) {
                    fread(dest, 1, compSize, f);
                } else if (method == 8) {
                    uint8_t *compData = malloc(compSize);
                    fread(compData, 1, compSize, f);
                    
                    z_stream strm;
                    strm.zalloc = Z_NULL;
                    strm.zfree = Z_NULL;
                    strm.opaque = Z_NULL;
                    strm.avail_in = compSize;
                    strm.next_in = compData;
                    strm.avail_out = uncompSize;
                    strm.next_out = dest;
                    
                    inflateInit2(&strm, -MAX_WBITS);
                    inflate(&strm, Z_FINISH);
                    inflateEnd(&strm);
                    
                    free(compData);
                }
                
                result = data;
                break;
            } else {
                fseek(f, compSize, SEEK_CUR);
            }
        } else {
            break;
        }
    }
    
    fclose(f);
    return result;
}

NSString* extractFileFromZip(NSString* zipPath, NSString* relativePath) {
    NSData *data = readFileFromZip(zipPath, relativePath);
    if (!data) return nil;
    
    NSString *tempDir = NSTemporaryDirectory();
    NSString *fileName = [relativePath lastPathComponent];
    NSString *tempPath = [tempDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Hynis_%@", fileName]];
    
    [data writeToFile:tempPath atomically:YES];
    return tempPath;
}