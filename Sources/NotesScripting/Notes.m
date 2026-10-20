/*
 * Notes.m
 */

#include "Notes.h"




/*
 * Standard Suite
 */

@implementation NotesApplication

typedef struct { NSString *name; FourCharCode code; } classForCode_t;
static const classForCode_t classForCodeData__[] = {
	{ @"NotesApplication", 'capp' },
	{ @"NotesDocument", 'docu' },
	{ @"NotesWindow", 'cwin' },
	{ @"NotesAccount", 'acct' },
	{ @"NotesFolder", 'cfol' },
	{ @"NotesNote", 'note' },
	{ @"NotesAttachment", 'atts' },
	{ nil, 0 } 
};

- (NSDictionary *) classNamesForCodes
{
	static NSMutableDictionary *dict__;

	if (!dict__) @synchronized([self class]) {
	if (!dict__) {
		dict__ = [[NSMutableDictionary alloc] init];
		const classForCode_t *p;
		for (p = classForCodeData__; p->name != nil; ++p)
			[dict__ setObject:p->name forKey:[NSNumber numberWithUnsignedInt:p->code]];
	} }
	return dict__;
}

typedef struct { FourCharCode code; NSString *name; } codeForPropertyName_t;
static const codeForPropertyName_t codeForPropertyNameData__[] = {
	{ 'lwcp', @"copies" },
	{ 'lwcl', @"collating" },
	{ 'lwfp', @"startingPage" },
	{ 'lwlp', @"endingPage" },
	{ 'lwla', @"pagesAcross" },
	{ 'lwld', @"pagesDown" },
	{ 'lwqt', @"requestedPrintTime" },
	{ 'lweh', @"errorHandling" },
	{ 'faxn', @"faxNumber" },
	{ 'trpr', @"targetPrinter" },
	{ 'pnam', @"name" },
	{ 'pisf', @"frontmost" },
	{ 'vers', @"version" },
	{ 'pnam', @"name" },
	{ 'imod', @"modified" },
	{ 'file', @"file" },
	{ 'pnam', @"name" },
	{ 'ID  ', @"id" },
	{ 'pidx', @"index" },
	{ 'pbnd', @"bounds" },
	{ 'hclb', @"closeable" },
	{ 'ismn', @"miniaturizable" },
	{ 'pmnd', @"miniaturized" },
	{ 'prsz', @"resizable" },
	{ 'pvis', @"visible" },
	{ 'iszm', @"zoomable" },
	{ 'pzum', @"zoomed" },
	{ 'docu', @"document" },
	{ 'dfac', @"defaultAccount" },
	{ 'seln', @"selection" },
	{ 'dfol', @"defaultFolder" },
	{ 'pnam', @"name" },
	{ 'upgr', @"upgraded" },
	{ 'ID  ', @"id" },
	{ 'pnam', @"name" },
	{ 'ID  ', @"id" },
	{ 'shrd', @"shared" },
	{ 'cntr', @"container" },
	{ 'pnam', @"name" },
	{ 'ID  ', @"id" },
	{ 'cntr', @"container" },
	{ 'body', @"body" },
	{ 'text', @"plaintext" },
	{ 'ascd', @"creationDate" },
	{ 'asmo', @"modificationDate" },
	{ 'pwpr', @"passwordProtected" },
	{ 'shrd', @"shared" },
	{ 'pnam', @"name" },
	{ 'ID  ', @"id" },
	{ 'cntr', @"container" },
	{ 'cid ', @"contentIdentifier" },
	{ 'ascd', @"creationDate" },
	{ 'asmo', @"modificationDate" },
	{ 'URL ', @"URL" },
	{ 'shrd', @"shared" },
	{ 0, nil } 
};

- (NSDictionary *) codesForPropertyNames
{
	static NSMutableDictionary *dict__;

	if (!dict__) @synchronized([self class]) {
	if (!dict__) {
		dict__ = [[NSMutableDictionary alloc] init];
		const codeForPropertyName_t *p;
		for (p = codeForPropertyNameData__; p->name != nil; ++p)
			[dict__ setObject:[NSNumber numberWithUnsignedInt:p->code] forKey:p->name];
	} }
	return dict__;
}


- (SBElementArray *) documents
{
	return [self elementArrayWithCode:'docu'];
}

- (SBElementArray *) windows
{
	return [self elementArrayWithCode:'cwin'];
}


- (NSString *) name
{
	return [[self propertyWithCode:'pnam'] get];
}

- (BOOL) frontmost
{
	id v = [[self propertyWithCode:'pisf'] get];
	return [v boolValue];
}

- (NSString *) version
{
	return [[self propertyWithCode:'vers'] get];
}


- (id) open:(id)x
{
	id result__ = [self sendEvent:'aevt' id:'odoc' parameters:'----', x, 0];
	return result__;
}

- (void) print:(id)x withProperties:(NSDictionary *)withProperties printDialog:(BOOL)printDialog
{
	[self sendEvent:'aevt' id:'pdoc' parameters:'----', x, 'prdt', withProperties, 'pdlg', [NSNumber numberWithBool:printDialog], 0];
}

- (void) quitSaving:(NotesSaveOptions)saving
{
	[self sendEvent:'aevt' id:'quit' parameters:'savo', [NSAppleEventDescriptor descriptorWithEnumCode:saving], 0];
}

- (BOOL) exists:(id)x
{
	id result__ = [self sendEvent:'core' id:'doex' parameters:'----', x, 0];
	return [result__ boolValue];
}

- (void) openNoteLocation:(NSString *)x
{
	[self sendEvent:'note' id:'open' parameters:'----', x, 0];
}

@end


@implementation NotesDocument

- (NSString *) name
{
	return [[self propertyWithCode:'pnam'] get];
}

- (BOOL) modified
{
	id v = [[self propertyWithCode:'imod'] get];
	return [v boolValue];
}

- (NSURL *) file
{
	return [[self propertyWithCode:'file'] get];
}



- (void) closeSaving:(NotesSaveOptions)saving savingIn:(NSURL *)savingIn
{
	[self sendEvent:'core' id:'clos' parameters:'savo', [NSAppleEventDescriptor descriptorWithEnumCode:saving], 'kfil', savingIn, 0];
}

- (void) saveIn:(NSURL *)in_ as:(NotesSaveableFileFormat)as
{
	[self sendEvent:'core' id:'save' parameters:'kfil', in_, 'fltp', [NSAppleEventDescriptor descriptorWithEnumCode:as], 0];
}

- (void) printWithProperties:(NSDictionary *)withProperties printDialog:(BOOL)printDialog
{
	[self sendEvent:'aevt' id:'pdoc' parameters:'prdt', withProperties, 'pdlg', [NSNumber numberWithBool:printDialog], 0];
}

- (void) delete
{
	[self sendEvent:'core' id:'delo' parameters:0];
}

- (void) duplicateTo:(SBObject *)to withProperties:(NSDictionary *)withProperties
{
	[self sendEvent:'core' id:'clon' parameters:'insh', to, 'prdt', withProperties, 0];
}

- (void) moveTo:(SBObject *)to
{
	[self sendEvent:'core' id:'move' parameters:'insh', to, 0];
}

@end


@implementation NotesWindow

- (NSString *) name
{
	return [[self propertyWithCode:'pnam'] get];
}

- (NSInteger) id
{
	id v = [[self propertyWithCode:'ID  '] get];
	return [v integerValue];
}

- (NSInteger) index
{
	id v = [[self propertyWithCode:'pidx'] get];
	return [v integerValue];
}

- (void) setIndex: (NSInteger) index
{
	id v = [NSNumber numberWithInteger:index];
	[[self propertyWithCode:'pidx'] setTo:v];
}

- (NSRect) bounds
{
	id v = [[self propertyWithCode:'pbnd'] get];
	return [v rectValue];
}

- (void) setBounds: (NSRect) bounds
{
	id v = [NSValue valueWithRect:bounds];
	[[self propertyWithCode:'pbnd'] setTo:v];
}

- (BOOL) closeable
{
	id v = [[self propertyWithCode:'hclb'] get];
	return [v boolValue];
}

- (BOOL) miniaturizable
{
	id v = [[self propertyWithCode:'ismn'] get];
	return [v boolValue];
}

- (BOOL) miniaturized
{
	id v = [[self propertyWithCode:'pmnd'] get];
	return [v boolValue];
}

- (void) setMiniaturized: (BOOL) miniaturized
{
	id v = [NSNumber numberWithBool:miniaturized];
	[[self propertyWithCode:'pmnd'] setTo:v];
}

- (BOOL) resizable
{
	id v = [[self propertyWithCode:'prsz'] get];
	return [v boolValue];
}

- (BOOL) visible
{
	id v = [[self propertyWithCode:'pvis'] get];
	return [v boolValue];
}

- (void) setVisible: (BOOL) visible
{
	id v = [NSNumber numberWithBool:visible];
	[[self propertyWithCode:'pvis'] setTo:v];
}

- (BOOL) zoomable
{
	id v = [[self propertyWithCode:'iszm'] get];
	return [v boolValue];
}

- (BOOL) zoomed
{
	id v = [[self propertyWithCode:'pzum'] get];
	return [v boolValue];
}

- (void) setZoomed: (BOOL) zoomed
{
	id v = [NSNumber numberWithBool:zoomed];
	[[self propertyWithCode:'pzum'] setTo:v];
}

- (NotesDocument *) document
{
	return (NotesDocument *) [self propertyWithClass:[NotesDocument class] code:'docu'];
}



- (void) closeSaving:(NotesSaveOptions)saving savingIn:(NSURL *)savingIn
{
	[self sendEvent:'core' id:'clos' parameters:'savo', [NSAppleEventDescriptor descriptorWithEnumCode:saving], 'kfil', savingIn, 0];
}

- (void) saveIn:(NSURL *)in_ as:(NotesSaveableFileFormat)as
{
	[self sendEvent:'core' id:'save' parameters:'kfil', in_, 'fltp', [NSAppleEventDescriptor descriptorWithEnumCode:as], 0];
}

- (void) printWithProperties:(NSDictionary *)withProperties printDialog:(BOOL)printDialog
{
	[self sendEvent:'aevt' id:'pdoc' parameters:'prdt', withProperties, 'pdlg', [NSNumber numberWithBool:printDialog], 0];
}

- (void) delete
{
	[self sendEvent:'core' id:'delo' parameters:0];
}

- (void) duplicateTo:(SBObject *)to withProperties:(NSDictionary *)withProperties
{
	[self sendEvent:'core' id:'clon' parameters:'insh', to, 'prdt', withProperties, 0];
}

- (void) moveTo:(SBObject *)to
{
	[self sendEvent:'core' id:'move' parameters:'insh', to, 0];
}

@end




/*
 * Notes Suite
 */

@implementation NotesApplication(NotesSuite)


- (SBElementArray *) accounts
{
	return [self elementArrayWithCode:'acct'];
}

- (SBElementArray *) folders
{
	return [self elementArrayWithCode:'cfol'];
}

- (SBElementArray *) notes
{
	return [self elementArrayWithCode:'note'];
}

- (SBElementArray *) attachments
{
	return [self elementArrayWithCode:'atts'];
}


- (NotesAccount *) defaultAccount
{
	return (NotesAccount *) [self propertyWithClass:[NotesAccount class] code:'dfac'];
}

- (void) setDefaultAccount: (NotesAccount *) defaultAccount
{
	[[self propertyWithClass:[NotesAccount class] code:'dfac'] setTo:defaultAccount];
}

- (NSArray<NotesNote *> *) selection
{
	return [[self propertyWithCode:'seln'] get];
}

- (void) setSelection: (NSArray<NotesNote *> *) selection
{
	[[self propertyWithCode:'seln'] setTo:selection];
}

@end


@implementation NotesAccount

- (SBElementArray *) folders
{
	return [self elementArrayWithCode:'cfol'];
}

- (SBElementArray *) notes
{
	return [self elementArrayWithCode:'note'];
}


- (NotesFolder *) defaultFolder
{
	return (NotesFolder *) [self propertyWithClass:[NotesFolder class] code:'dfol'];
}

- (void) setDefaultFolder: (NotesFolder *) defaultFolder
{
	[[self propertyWithClass:[NotesFolder class] code:'dfol'] setTo:defaultFolder];
}

- (NSString *) name
{
	return [[self propertyWithCode:'pnam'] get];
}

- (void) setName: (NSString *) name
{
	[[self propertyWithCode:'pnam'] setTo:name];
}

- (BOOL) upgraded
{
	id v = [[self propertyWithCode:'upgr'] get];
	return [v boolValue];
}

- (NSString *) id
{
	return [[self propertyWithCode:'ID  '] get];
}


- (id) showSeparately:(BOOL)separately
{
	id result__ = [self sendEvent:'note' id:'show' parameters:'sepa', [NSNumber numberWithBool:separately], 0];
	return result__;
}


- (void) closeSaving:(NotesSaveOptions)saving savingIn:(NSURL *)savingIn
{
	[self sendEvent:'core' id:'clos' parameters:'savo', [NSAppleEventDescriptor descriptorWithEnumCode:saving], 'kfil', savingIn, 0];
}

- (void) saveIn:(NSURL *)in_ as:(NotesSaveableFileFormat)as
{
	[self sendEvent:'core' id:'save' parameters:'kfil', in_, 'fltp', [NSAppleEventDescriptor descriptorWithEnumCode:as], 0];
}

- (void) printWithProperties:(NSDictionary *)withProperties printDialog:(BOOL)printDialog
{
	[self sendEvent:'aevt' id:'pdoc' parameters:'prdt', withProperties, 'pdlg', [NSNumber numberWithBool:printDialog], 0];
}

- (void) delete
{
	[self sendEvent:'core' id:'delo' parameters:0];
}

- (void) duplicateTo:(SBObject *)to withProperties:(NSDictionary *)withProperties
{
	[self sendEvent:'core' id:'clon' parameters:'insh', to, 'prdt', withProperties, 0];
}

- (void) moveTo:(SBObject *)to
{
	[self sendEvent:'core' id:'move' parameters:'insh', to, 0];
}

@end


@implementation NotesFolder

- (SBElementArray *) folders
{
	return [self elementArrayWithCode:'cfol'];
}

- (SBElementArray *) notes
{
	return [self elementArrayWithCode:'note'];
}


- (NSString *) name
{
	return [[self propertyWithCode:'pnam'] get];
}

- (void) setName: (NSString *) name
{
	[[self propertyWithCode:'pnam'] setTo:name];
}

- (NSString *) id
{
	return [[self propertyWithCode:'ID  '] get];
}

- (BOOL) shared
{
	id v = [[self propertyWithCode:'shrd'] get];
	return [v boolValue];
}

- (id) container
{
	return (id) [self propertyWithCode:'cntr'];
}


- (id) showSeparately:(BOOL)separately
{
	id result__ = [self sendEvent:'note' id:'show' parameters:'sepa', [NSNumber numberWithBool:separately], 0];
	return result__;
}


- (void) closeSaving:(NotesSaveOptions)saving savingIn:(NSURL *)savingIn
{
	[self sendEvent:'core' id:'clos' parameters:'savo', [NSAppleEventDescriptor descriptorWithEnumCode:saving], 'kfil', savingIn, 0];
}

- (void) saveIn:(NSURL *)in_ as:(NotesSaveableFileFormat)as
{
	[self sendEvent:'core' id:'save' parameters:'kfil', in_, 'fltp', [NSAppleEventDescriptor descriptorWithEnumCode:as], 0];
}

- (void) printWithProperties:(NSDictionary *)withProperties printDialog:(BOOL)printDialog
{
	[self sendEvent:'aevt' id:'pdoc' parameters:'prdt', withProperties, 'pdlg', [NSNumber numberWithBool:printDialog], 0];
}

- (void) delete
{
	[self sendEvent:'core' id:'delo' parameters:0];
}

- (void) duplicateTo:(SBObject *)to withProperties:(NSDictionary *)withProperties
{
	[self sendEvent:'core' id:'clon' parameters:'insh', to, 'prdt', withProperties, 0];
}

- (void) moveTo:(SBObject *)to
{
	[self sendEvent:'core' id:'move' parameters:'insh', to, 0];
}

@end


@implementation NotesNote

- (SBElementArray *) attachments
{
	return [self elementArrayWithCode:'atts'];
}


- (NSString *) name
{
	return [[self propertyWithCode:'pnam'] get];
}

- (void) setName: (NSString *) name
{
	[[self propertyWithCode:'pnam'] setTo:name];
}

- (NSString *) id
{
	return [[self propertyWithCode:'ID  '] get];
}

- (NotesFolder *) container
{
	return (NotesFolder *) [self propertyWithClass:[NotesFolder class] code:'cntr'];
}

- (NSString *) body
{
	return [[self propertyWithCode:'body'] get];
}

- (void) setBody: (NSString *) body
{
	[[self propertyWithCode:'body'] setTo:body];
}

- (NSString *) plaintext
{
	return [[self propertyWithCode:'text'] get];
}

- (NSDate *) creationDate
{
	return [[self propertyWithCode:'ascd'] get];
}

- (NSDate *) modificationDate
{
	return [[self propertyWithCode:'asmo'] get];
}

- (BOOL) passwordProtected
{
	id v = [[self propertyWithCode:'pwpr'] get];
	return [v boolValue];
}

- (BOOL) shared
{
	id v = [[self propertyWithCode:'shrd'] get];
	return [v boolValue];
}


- (id) showSeparately:(BOOL)separately
{
	id result__ = [self sendEvent:'note' id:'show' parameters:'sepa', [NSNumber numberWithBool:separately], 0];
	return result__;
}


- (void) closeSaving:(NotesSaveOptions)saving savingIn:(NSURL *)savingIn
{
	[self sendEvent:'core' id:'clos' parameters:'savo', [NSAppleEventDescriptor descriptorWithEnumCode:saving], 'kfil', savingIn, 0];
}

- (void) saveIn:(NSURL *)in_ as:(NotesSaveableFileFormat)as
{
	[self sendEvent:'core' id:'save' parameters:'kfil', in_, 'fltp', [NSAppleEventDescriptor descriptorWithEnumCode:as], 0];
}

- (void) printWithProperties:(NSDictionary *)withProperties printDialog:(BOOL)printDialog
{
	[self sendEvent:'aevt' id:'pdoc' parameters:'prdt', withProperties, 'pdlg', [NSNumber numberWithBool:printDialog], 0];
}

- (void) delete
{
	[self sendEvent:'core' id:'delo' parameters:0];
}

- (void) duplicateTo:(SBObject *)to withProperties:(NSDictionary *)withProperties
{
	[self sendEvent:'core' id:'clon' parameters:'insh', to, 'prdt', withProperties, 0];
}

- (void) moveTo:(SBObject *)to
{
	[self sendEvent:'core' id:'move' parameters:'insh', to, 0];
}

@end


@implementation NotesAttachment

- (NSString *) name
{
	return [[self propertyWithCode:'pnam'] get];
}

- (NSString *) id
{
	return [[self propertyWithCode:'ID  '] get];
}

- (NotesNote *) container
{
	return (NotesNote *) [self propertyWithClass:[NotesNote class] code:'cntr'];
}

- (NSString *) contentIdentifier
{
	return [[self propertyWithCode:'cid '] get];
}

- (NSDate *) creationDate
{
	return [[self propertyWithCode:'ascd'] get];
}

- (NSDate *) modificationDate
{
	return [[self propertyWithCode:'asmo'] get];
}

- (NSString *) URL
{
	return [[self propertyWithCode:'URL '] get];
}

- (BOOL) shared
{
	id v = [[self propertyWithCode:'shrd'] get];
	return [v boolValue];
}


- (id) showSeparately:(BOOL)separately
{
	id result__ = [self sendEvent:'note' id:'show' parameters:'sepa', [NSNumber numberWithBool:separately], 0];
	return result__;
}


- (void) closeSaving:(NotesSaveOptions)saving savingIn:(NSURL *)savingIn
{
	[self sendEvent:'core' id:'clos' parameters:'savo', [NSAppleEventDescriptor descriptorWithEnumCode:saving], 'kfil', savingIn, 0];
}

- (void) saveIn:(NSURL *)in_ as:(NotesSaveableFileFormat)as
{
	[self sendEvent:'core' id:'save' parameters:'kfil', in_, 'fltp', [NSAppleEventDescriptor descriptorWithEnumCode:as], 0];
}

- (void) printWithProperties:(NSDictionary *)withProperties printDialog:(BOOL)printDialog
{
	[self sendEvent:'aevt' id:'pdoc' parameters:'prdt', withProperties, 'pdlg', [NSNumber numberWithBool:printDialog], 0];
}

- (void) delete
{
	[self sendEvent:'core' id:'delo' parameters:0];
}

- (void) duplicateTo:(SBObject *)to withProperties:(NSDictionary *)withProperties
{
	[self sendEvent:'core' id:'clon' parameters:'insh', to, 'prdt', withProperties, 0];
}

- (void) moveTo:(SBObject *)to
{
	[self sendEvent:'core' id:'move' parameters:'insh', to, 0];
}

@end


