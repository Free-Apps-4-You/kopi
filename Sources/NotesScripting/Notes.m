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

- (NSRect) bounds
{
	id v = [[self propertyWithCode:'pbnd'] get];
	return [v rectValue];
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

- (NotesDocument *) document
{
	return (NotesDocument *) [self propertyWithClass:[NotesDocument class] code:'docu'];
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

- (NSArray<NotesNote *> *) selection
{
	return [[self propertyWithCode:'seln'] get];
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

- (NSString *) name
{
	return [[self propertyWithCode:'pnam'] get];
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


@end


