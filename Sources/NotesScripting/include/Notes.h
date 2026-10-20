/*
 * Notes.h
 */

#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>


@class NotesApplication, NotesDocument, NotesWindow, NotesAccount, NotesFolder, NotesNote, NotesAttachment;

// Read-only subset of the Notes scripting dictionary.
@protocol NotesGenericMethods


@end



/*
 * Standard Suite
 */

// The application's top-level scripting object.
@interface NotesApplication : SBApplication

- (SBElementArray<NotesDocument *> *) documents;
- (SBElementArray<NotesWindow *> *) windows;

@property (copy, readonly) NSString *name;  // The name of the application.
@property (readonly) BOOL frontmost;  // Is this the active application?
@property (copy, readonly) NSString *version;  // The version number of the application.

- (id) open:(id)x;  // Open a document.
- (BOOL) exists:(id)x;  // Verify that an object exists.
- (void) openNoteLocation:(NSString *)x;  // Open a note URL.

@end

// A document.
@interface NotesDocument : SBObject <NotesGenericMethods>

@property (copy, readonly) NSString *name;  // Its name.
@property (readonly) BOOL modified;  // Has it been modified since the last save?
@property (copy, readonly) NSURL *file;  // Its location on disk, if it has one.


@end

// A window.
@interface NotesWindow : SBObject <NotesGenericMethods>

@property (copy, readonly) NSString *name;  // The title of the window.
- (NSInteger) id;  // The unique identifier of the window.
@property (readonly) NSInteger index;  // The index of the window, ordered front to back.
@property (readonly) NSRect bounds;  // The bounding rectangle of the window.
@property (readonly) BOOL closeable;  // Does the window have a close button?
@property (readonly) BOOL miniaturizable;  // Does the window have a minimize button?
@property (readonly) BOOL miniaturized;  // Is the window minimized right now?
@property (readonly) BOOL resizable;  // Can the window be resized?
@property (readonly) BOOL visible;  // Is the window visible right now?
@property (readonly) BOOL zoomable;  // Does the window have a zoom button?
@property (readonly) BOOL zoomed;  // Is the window zoomed right now?
@property (copy, readonly) NotesDocument *document;  // The document whose contents are displayed in the window.


@end



/*
 * Notes Suite
 */

// the Notes application
@interface NotesApplication (NotesSuite)

- (SBElementArray<NotesAccount *> *) accounts;
- (SBElementArray<NotesFolder *> *) folders;
- (SBElementArray<NotesNote *> *) notes;
- (SBElementArray<NotesAttachment *> *) attachments;

@property (copy, readonly) NotesAccount *defaultAccount;  // the default account for creating notes
@property (copy, readonly) NSArray<NotesNote *> *selection;  // the selected note(s)

@end

// a Notes account
@interface NotesAccount : SBObject <NotesGenericMethods>

- (SBElementArray<NotesFolder *> *) folders;
- (SBElementArray<NotesNote *> *) notes;

@property (copy, readonly) NotesFolder *defaultFolder;  // the default folder for creating notes
@property (copy, readonly) NSString *name;  // the name of the account
@property (readonly) BOOL upgraded;  // Is the account upgraded?
- (NSString *) id;  // the unique identifier of the account

- (id) showSeparately:(BOOL)separately;  // Show an object in the UI

@end

// a folder containing notes
@interface NotesFolder : SBObject <NotesGenericMethods>

- (SBElementArray<NotesFolder *> *) folders;
- (SBElementArray<NotesNote *> *) notes;

@property (copy, readonly) NSString *name;  // the name of the folder
- (NSString *) id;  // the unique identifier of the folder
@property (readonly) BOOL shared;  // Is the folder shared?
@property (copy, readonly) id container;  // the container of the folder

- (id) showSeparately:(BOOL)separately;  // Show an object in the UI

@end

// a note in the Notes application
@interface NotesNote : SBObject <NotesGenericMethods>

- (SBElementArray<NotesAttachment *> *) attachments;

@property (copy, readonly) NSString *name;  // the name of the note (normally the first line of the body)
- (NSString *) id;  // the unique identifier of the note
@property (copy, readonly) NotesFolder *container;  // the folder of the note
@property (copy, readonly) NSString *body;  // the HTML content of the note
@property (copy, readonly) NSString *plaintext;  // the plaintext content of the note
@property (copy, readonly) NSDate *creationDate;  // the creation date of the note
@property (copy, readonly) NSDate *modificationDate;  // the modification date of the note
@property (readonly) BOOL passwordProtected;  // Is the note password protected?
@property (readonly) BOOL shared;  // Is the note shared?

- (id) showSeparately:(BOOL)separately;  // Show an object in the UI

@end

// an attachment in a note
@interface NotesAttachment : SBObject <NotesGenericMethods>

@property (copy, readonly) NSString *name;  // the name of the attachment
- (NSString *) id;  // the unique identifier of the attachment
@property (copy, readonly) NotesNote *container;  // the note containing the attachment
@property (copy, readonly) NSString *contentIdentifier;  // the content-id URL in the note's HTML
@property (copy, readonly) NSDate *creationDate;  // the creation date of the attachment
@property (copy, readonly) NSDate *modificationDate;  // the modification date of the attachment
@property (copy, readonly) NSString *URL;  // for URL attachments, the URL the attachment represents
@property (readonly) BOOL shared;  // Is the attachment shared?

- (id) showSeparately:(BOOL)separately;  // Show an object in the UI

@end

