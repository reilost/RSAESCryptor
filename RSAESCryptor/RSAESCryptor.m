//
//  RSAESCryptor.m
//  RSAESCryptor
//
//  Created by San Chen on 7/15/12.
//  Copyright (c) 2012 Learningtech. All rights reserved.
//

#import "RSAESCryptor.h"
#import "NSData+Base64.h"
#import "NSData+CommonCrypto.h"
#import <Security/Security.h>

@interface RSAESCryptor() {
    SecKeyRef _publicKeyRef;
    SecKeyRef _privateKeyRef;
}

+ (NSData *)randomDataOfLength:(size_t)length;
- (NSData *)generateKey;
- (NSData *)generateIV;
- (NSData *)wrapSymmetricKey:(NSData *)symmetricKey keyRef:(SecKeyRef)publicKey;
- (NSData *)unwrapSymmetricKey:(NSData *)wrappedSymmetricKey keyRef:(SecKeyRef)privateKey;

@end

@implementation RSAESCryptor

+ (RSAESCryptor *)sharedCryptor
{
    static dispatch_once_t once;
    static RSAESCryptor *cryptor = nil;
    
    dispatch_once(&once, ^{cryptor = [[self alloc] init];});
    return cryptor;
}

#pragma mark -
+ (NSData *)randomDataOfLength:(size_t)length
{
    NSMutableData *data = [NSMutableData dataWithLength:length];
    
    int result = SecRandomCopyBytes(kSecRandomDefault, length, data.mutableBytes);
    NSAssert(result == 0, @"Unable to generate random bytes: %d", errno);
    
    return data;
}

- (NSData *)generateKey {
    return [[self class] randomDataOfLength:kCCKeySizeAES256];
}

- (NSData *)generateIV {
    return [[self class] randomDataOfLength:kCCBlockSizeAES128];
}

- (NSData *)wrapSymmetricKey:(NSData *)symmetricKey keyRef:(SecKeyRef)publicKey {
	size_t keyBufferSize = [symmetricKey length];	
	size_t cipherBufferSize = SecKeyGetBlockSize(publicKey);
    
    NSMutableData *cipher = [NSMutableData dataWithLength:cipherBufferSize];
	OSStatus sanityCheck = SecKeyEncrypt(publicKey,
                                         kSecPaddingPKCS1,
                                         (const uint8_t *)[symmetricKey bytes],
                                         keyBufferSize,
                                         cipher.mutableBytes,
                                         &cipherBufferSize);
    NSAssert(sanityCheck == noErr, @"Error encrypting, OSStatus == %d.", sanityCheck);
    
    return cipher;
}

- (NSData *)unwrapSymmetricKey:(NSData *)wrappedSymmetricKey keyRef:(SecKeyRef)privateKey {
    size_t cipherBufferSize = SecKeyGetBlockSize(privateKey);
    size_t keyBufferSize = [wrappedSymmetricKey length];

    NSMutableData *key = [NSMutableData dataWithLength:keyBufferSize];
    OSStatus sanityCheck = SecKeyDecrypt(privateKey,
                                         kSecPaddingPKCS1,
                                         (const uint8_t *) [wrappedSymmetricKey bytes],
                                         cipherBufferSize,
                                         [key mutableBytes],
                                         &keyBufferSize);
    NSAssert(sanityCheck == noErr, @"Error decrypting, OSStatus == %d.", sanityCheck);

    return key;
}

#pragma mark -
- (void)loadPublicKey:(NSString *)keyPath {
    [self releaseSecVars];
    
    NSData *certificateData = [NSData dataWithContentsOfFile:keyPath];
    
    SecCertificateRef certificateRef = SecCertificateCreateWithData(kCFAllocatorDefault, (__bridge CFDataRef)certificateData);
    SecPolicyRef policyRef = SecPolicyCreateBasicX509();
    SecTrustRef trustRef;
    
    OSStatus status = SecTrustCreateWithCertificates(certificateRef, policyRef, &trustRef);
    NSAssert(status == errSecSuccess, @"SecTrustCreateWithCertificates failed.");

    SecTrustResultType trustResult;
    status = SecTrustEvaluate(trustRef, &trustResult);
    NSAssert(status == errSecSuccess, @"SecTrustEvaluate failed.");
    
    _publicKeyRef = SecTrustCopyPublicKey(trustRef);
    NSAssert(_publicKeyRef != NULL, @"SecTrustCopyPublicKey failed.");
    
    if (certificateRef) CFRelease(certificateRef);
    if (policyRef) CFRelease(policyRef);
    if (trustRef) CFRelease(trustRef);
}

- (NSData *)encryptData:(NSData *)content {
    // generate key
    NSData *aesKey = [self generateKey];
    NSLog(@"aesKey length = %d, base64 = %@", [aesKey length], [aesKey base64EncodedString]);
    
    // generate iv
    NSData *iv = [self generateIV];
    NSLog(@"iv length = %d, base64 = %@", [iv length], [iv base64EncodedString]);
    
    // encrypt data with aesKey
    NSData *encryptedData = [content AES256EncryptedDataUsingKey:aesKey andIV:iv error:nil];
    NSLog(@"encryptedData length = %d, base64 = %@", [encryptedData length], [encryptedData base64EncodedString]);
    
    // encrypt aesKey with publicKey
    NSData *encryptedAESKey = [self wrapSymmetricKey:aesKey keyRef:_publicKeyRef];
    NSLog(@"encryptedAESKey length = %d", [encryptedAESKey length]);
    
    NSMutableData *result = [NSMutableData data];
    [result appendData:iv];
    [result appendData:encryptedAESKey];
    [result appendData:encryptedData];
    return result;
}

- (void)loadPrivateKey:(NSString *)keyPath password:(NSString *)password {
    [self releaseSecVars];
    
    NSData *PKCS12Data = [NSData dataWithContentsOfFile:keyPath];

    CFDataRef inPKCS12Data = (__bridge CFDataRef)PKCS12Data;
    
    SecIdentityRef myIdentity;
    SecTrustRef myTrust;
    
    CFStringRef passwordRef = (__bridge CFStringRef)password;
    const void *keys[] =   { kSecImportExportPassphrase };
    const void *values[] = { passwordRef };
    CFDictionaryRef optionsDictionary = CFDictionaryCreate(NULL, keys,
                                                           values, 1,
                                                           NULL, NULL);
    
    CFArrayRef items = CFArrayCreate(NULL, 0, 0, NULL);

    OSStatus securityError = SecPKCS12Import(inPKCS12Data,
                                             optionsDictionary,
                                             &items);
    
    if (securityError == 0) {
        CFDictionaryRef myIdentityAndTrust = CFArrayGetValueAtIndex(items, 0);
        const void *tempIdentity = NULL;
        tempIdentity = CFDictionaryGetValue(myIdentityAndTrust,
                                            kSecImportItemIdentity);
        myIdentity = (SecIdentityRef)tempIdentity;
        const void *tempTrust = NULL;
        tempTrust = CFDictionaryGetValue (myIdentityAndTrust, kSecImportItemTrust);
        myTrust = (SecTrustRef)tempTrust;
    }
    
    if (optionsDictionary)
        CFRelease(optionsDictionary);
    
    SecTrustResultType trustResult;
    if (securityError == noErr) {
        securityError = SecTrustEvaluate(myTrust, &trustResult);
    }
    SecIdentityCopyPrivateKey(myIdentity, &_privateKeyRef);
}

- (NSData *)decryptData:(NSData *)content {
    NSData *iv = [content subdataWithRange:NSMakeRange(0, 16)];
    NSData *wrappedSymmetricKey = [content subdataWithRange:NSMakeRange(16, 256)];
    NSData *encryptedData = [content subdataWithRange:NSMakeRange(272, [content length] - 272)];
    
    NSData *key = [self unwrapSymmetricKey:wrappedSymmetricKey keyRef:_privateKeyRef];
    
    return [encryptedData decryptedAES256DataUsingKey:key andIV:iv error:nil];
}

#pragma mark -
- (void)releaseSecVars {
    if (_publicKeyRef) CFRelease(_publicKeyRef);
    if (_privateKeyRef) CFRelease(_privateKeyRef);
}

- (void)dealloc {
    [self releaseSecVars];
}

@end
