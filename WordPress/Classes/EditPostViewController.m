#import "EditPostViewController_Internal.h"
#import "AutosavingIndicatorView.h"
#import "ContextManager.h"
#import "IOS7CorrectedTextView.h"
#import "NSString+XMLExtensions.h"
#import "Post.h"
#import "WPAddCategoryViewController.h"
#import "WPAlertView.h"

NSTimeInterval kAnimationDuration = 0.3f;

NSUInteger const EditPostViewControllerCharactersChangedToAutosave = 50;
NSUInteger const EditPostViewControllerCharactersChangedToAutosaveOnWWAN = 100;

typedef NS_ENUM(NSInteger, EditPostViewControllerAlertTag) {
    EditPostViewControllerAlertTagNone,
    EditPostViewControllerAlertTagLinkHelper,
    EditPostViewControllerAlertTagFailedMedia,
};

NSString *const EditPostViewControllerLastUsedBlogURL = @"EditPostViewControllerLastUsedBlogURL";
NSString *const EditPostViewControllerDidAutosaveNotification = @"EditPostViewControllerDidAutosaveNotification";
NSString *const EditPostViewControllerAutosaveDidFailNotification = @"EditPostViewControllerAutosaveDidFailNotification";

@interface EditPostViewController ()

@property (nonatomic, strong) WPAlertView *linkHelperAlertView;
@property (nonatomic, assign) BOOL hasChangesToAutosave;

@end

@implementation EditPostViewController {
    IBOutlet IOS7CorrectedTextView *textView;
    IBOutlet UITextField *titleTextField;
    IBOutlet UILabel *tapToStartWritingLabel;
    IBOutlet UIView *separatorView;
    IBOutlet UIBarButtonItem *previewButton;
    IBOutlet UIBarButtonItem *leftPreviewSpacer;
    IBOutlet UIBarButtonItem *rightPreviewSpacer;
    IBOutlet UIBarButtonItem *rightMediaSpacer;

    UIActionSheet *currentActionSheet;
    UIAlertView *_failedMediaAlertView;
    UITextField *__weak currentEditingTextField;
    AutosavingIndicatorView *_autosavingIndicatorView;
    WPKeyboardToolbarBase *editorToolbar;

    BOOL isShowingKeyboard;
    BOOL isExternalKeyboard;
    BOOL _isAutosaved;
    BOOL _isAutosaving;
    NSUInteger _charactersChanged;
    AbstractPost *_backupPost;
}

#define USE_AUTOSAVES 0

#pragma mark -
#pragma mark LifeCycle Methods

CGFloat const EditPostViewControllerStandardOffset = 15.0;
CGFloat const EditPostViewControllerTextViewOffset = 10.0;

+ (Blog *)blogForNewDraft {
    // Try to get the last used blog, if there is one.
    NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"Blog"];
    NSString *url = [[NSUserDefaults standardUserDefaults] stringForKey:EditPostViewControllerLastUsedBlogURL];
    if (url) {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"url = %@", url];
        [fetchRequest setPredicate:predicate];
    }
    fetchRequest.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"blogName" ascending:YES]];
    NSFetchedResultsController *resultsController = [[NSFetchedResultsController alloc]
                                                     initWithFetchRequest:fetchRequest
                                                     managedObjectContext:[[ContextManager sharedInstance] mainContext]
                                                     sectionNameKeyPath:nil
                                                     cacheName:nil];
    NSError *error = nil;
    if (![resultsController performFetch:&error]) {
        DDLogError(@"Couldn't fetch blogs: %@", [error localizedDescription]);
        return nil;
    }
    
    if([resultsController.fetchedObjects count] == 0) {
        if (url) {
            // Blog might have been removed from the app. Get the first available.
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:EditPostViewControllerLastUsedBlogURL];
            [[NSUserDefaults standardUserDefaults] synchronize];
            return [self blogForNewDraft];
        }
        return nil;
    }
    
    return [resultsController.fetchedObjects objectAtIndex:0];
}

- (void)dealloc {
    _failedMediaAlertView.delegate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (id)initWithDraftForLastUsedBlog {
    Blog *blog = [EditPostViewController blogForNewDraft];
    return [self initWithPost:[Post newDraftForBlog:blog]];
}

- (id)initWithPost:(AbstractPost *)aPost {
    self = [super initWithNibName:@"EditPostViewControlleriOS7" bundle:nil];
    if (self) {
        self.apost = aPost;
        [[NSUserDefaults standardUserDefaults] setObject:aPost.blog.url forKey:EditPostViewControllerLastUsedBlogURL];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        if (self.apost.remoteStatus == AbstractPostRemoteStatusLocal) {
            self.editMode = EditPostViewControllerModeNewPost;
        } else {
            self.editMode = EditPostViewControllerModeEditPost;
        }
    }
    return self;
}

- (void)viewDidLoad {
    WPFLogMethod();
    [super viewDidLoad];
    
    self.navigationController.navigationBar.translucent = NO;
    if(self.navigationController.navigationBarHidden) {
        [self.navigationController setNavigationBarHidden:NO animated:YES];
    }
    
    // Using performBlock: with the AbstractPost on the main context:
    // Prevents a hang on opening this view on slow and fast devices
    // by deferring the cloning and UI update.
    // Slower devices have the effect of the content appearing after
    // a short delay
    [self.apost.managedObjectContext performBlock:^{
        self.apost = [self.apost createRevision];
        [self.apost save];
        [self refreshUIForCurrentPost];
    }];
   
#if USE_AUTOSAVES
    _backupPost = [NSEntityDescription insertNewObjectForEntityForName:[[aPost entity] name] inManagedObjectContext:[aPost managedObjectContext]];
    [_backupPost cloneFrom:aPost];
#endif
    
    tapToStartWritingLabel.text = NSLocalizedString(@"Tap here to begin writing", @"Placeholder for the main body text. Should hint at tapping to enter text (not specifying body text).");
	tapToStartWritingLabel.textAlignment = NSTextAlignmentCenter;

    // Setup Line Height
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.minimumLineHeight = 24;
    style.maximumLineHeight = 24;
    textView.typingAttributes = @{ NSParagraphStyleAttributeName: style };
    
    // Set title frame
    CGRect titleFrame = titleTextField.frame;
    titleFrame.origin.x = EditPostViewControllerStandardOffset;
    titleFrame.size.width = CGRectGetWidth(self.view.bounds) - 2*EditPostViewControllerStandardOffset;
    titleTextField.frame = titleFrame;
    
    // Set separator frame
    CGRect separatorFrame = separatorView.frame;
    separatorFrame.origin.y = CGRectGetMaxY(titleFrame);
    separatorFrame.origin.x = EditPostViewControllerStandardOffset;
    separatorFrame.size.width = CGRectGetWidth(self.view.bounds) - EditPostViewControllerStandardOffset;
    separatorView.frame = separatorFrame;
    separatorView.backgroundColor = [WPStyleGuide readGrey];
    
    textView.textContainerInset = UIEdgeInsetsMake(0.0f, EditPostViewControllerTextViewOffset, 0.0f, EditPostViewControllerTextViewOffset);

    
    if (editorToolbar == nil) {
        CGRect frame = CGRectMake(0, 0, self.view.frame.size.width, WPKT_HEIGHT_PORTRAIT);
        editorToolbar = [[WPKeyboardToolbarWithoutGradient alloc] initWithFrame:frame];
        editorToolbar.delegate = self;
    }
    textView.inputAccessoryView = editorToolbar;

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(insertMediaAbove:) name:@"ShouldInsertMediaAbove" object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(insertMediaBelow:) name:@"ShouldInsertMediaBelow" object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(removeMedia:) name:@"ShouldRemoveMedia" object:nil];	
	
    if (_autosavingIndicatorView == nil) {
        _autosavingIndicatorView = [[AutosavingIndicatorView alloc] initWithFrame:CGRectZero];
        _autosavingIndicatorView.hidden = YES;
        _autosavingIndicatorView.alpha = 0.9f;

        [self.view addSubview:_autosavingIndicatorView];
        [self positionAutosaveView:nil];
    }
    
    titleTextField.font = [WPStyleGuide postTitleFont];
    textView.font = [WPStyleGuide regularTextFont];
    self.view.backgroundColor = [WPStyleGuide itsEverywhereGrey];
    self.toolbar.translucent = NO;
    self.toolbar.barStyle = UIBarStyleDefault;
    titleTextField.placeholder = NSLocalizedString(@"Enter title here", @"Label for the title of the post field. Should be the same as WP core.");
    titleTextField.textColor = [WPStyleGuide littleEddieGrey];
    textView.textColor = [WPStyleGuide littleEddieGrey];
    self.toolbar.barTintColor = [WPStyleGuide littleEddieGrey];
    self.navigationController.navigationBar.translucent = NO;
    leftPreviewSpacer.width = -6.5;
    rightPreviewSpacer.width = 5.0;
    rightMediaSpacer.width = -5.0;
    
    for (UIView *item in self.toolbar.subviews) {
        if ([item respondsToSelector:@selector(setExclusiveTouch:)]) {
            [item setExclusiveTouch:YES];
        }
    }
    
    [WPMobileStats trackEventForWPCom:[self formattedStatEventString:StatsEventPostDetailOpenedEditor]];
}

- (void)viewWillAppear:(BOOL)animated {
    WPFLogMethod();
    [super viewWillAppear:animated];

    self.title = [self editorTitle];
    self.navigationItem.title = [self editorTitle];

	[self refreshButtons];
	
    textView.frame = [self normalTextFrame];
    tapToStartWritingLabel.frame = [self textviewPlaceholderFrame];
    [textView setContentOffset:CGPointMake(0, 0)];

	CABasicAnimation *animateWiggleIt;
	animateWiggleIt = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
	animateWiggleIt.duration = 0.5;
	animateWiggleIt.repeatCount = 1;
	animateWiggleIt.autoreverses = NO;
    animateWiggleIt.fromValue = @0.75f;
    animateWiggleIt.toValue = @1.f;
	[tapToStartWritingLabel.layer addAnimation:animateWiggleIt forKey:@"placeholderWiggle"];

}

- (void)viewWillDisappear:(BOOL)animated {
    WPFLogMethod();
    [super viewWillDisappear:animated];
    
	[titleTextField resignFirstResponder];
	[textView resignFirstResponder];
}

- (NSString *)statsPrefix {
    if (_statsPrefix == nil) {
        return @"Post Detail";
    }
    return _statsPrefix;
}

- (NSString *)formattedStatEventString:(NSString *)event {
    return [NSString stringWithFormat:@"%@ - %@", self.statsPrefix, event];
}

#pragma mark -
#pragma mark Instance Methods

- (NSString *)editorTitle {
    NSString *title = @"";
    if (self.editMode == EditPostViewControllerModeNewPost) {
        title = NSLocalizedString(@"New Post", @"Post Editor screen title.");
    } else {
        if ([self.apost.postTitle length]) {
            title = self.apost.postTitle;
        } else {
            title = NSLocalizedString(@"Edit Post", @"Post Editor screen title.");
        }
    }
    self.navigationItem.backBarButtonItem.title = title;
    return title;
}

- (Post *)post {
    if ([self.apost isKindOfClass:[Post class]]) {
        return (Post *)self.apost;
    } else {
        return nil;
    }
}

- (IBAction)showSettings:(id)sender {
    [WPMobileStats flagProperty:StatsPropertyPostDetailClickedSettings forEvent:[self formattedStatEventString:StatsEventPostDetailClosedEditor]];
    PostSettingsViewController *vc = [[PostSettingsViewController alloc] initWithPost:self.apost];
    vc.statsPrefix = self.statsPrefix;
    vc.postDetailViewController = self;
    self.navigationItem.title = NSLocalizedString(@"Back", nil);
    [self.navigationController pushViewController:vc animated:YES];
}

- (IBAction)showPreview:(id)sender {
    [WPMobileStats flagProperty:StatsPropertyPostDetailClickedPreview forEvent:[self formattedStatEventString:StatsEventPostDetailClosedEditor]];

    PostPreviewViewController *vc = [[PostPreviewViewController alloc] initWithPost:self.apost];
    vc.postDetailViewController = self;
    self.navigationItem.title = NSLocalizedString(@"Back", nil);
    [self.navigationController pushViewController:vc animated:YES];
}

- (IBAction)showMediaOptions:(id)sender {
    [WPMobileStats flagProperty:StatsPropertyPostDetailClickedMediaOptions forEvent:[self formattedStatEventString:StatsEventPostDetailClosedEditor]];
    PostMediaViewController *vc = [[PostMediaViewController alloc] initWithPost:self.apost];
    UIBarButtonItem *backButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Back", @"") style:UIBarButtonItemStyleBordered target:nil action:nil];
    self.navigationItem.backBarButtonItem = backButton;
    
    [self.navigationController pushViewController:vc animated:YES];
}

- (CGRect)normalTextFrame {
    CGFloat x = 0.0;
    CGFloat y = CGRectGetMaxY(separatorView.frame);
    CGFloat height = self.toolbar.frame.origin.y - y;
    return CGRectMake(x, y, self.view.bounds.size.width, height);
}

- (CGRect)textviewPlaceholderFrame {
    return CGRectInset(textView.frame, 7.f, 7.f);
}

- (void)deleteBackupPost {
    if (_backupPost) {
        NSManagedObjectContext *moc = _backupPost.managedObjectContext;
        [moc deleteObject:_backupPost];
        NSError *error;
        [moc save:&error];
        _backupPost = nil;
    }
}

- (void)restoreBackupPost:(BOOL)upload {
    if (_backupPost) {
        [self.apost.original cloneFrom:_backupPost];
        if (upload) {
            DDLogInfo(@"Restoring post backup");
            [self.apost.original uploadWithSuccess:^{
                DDLogInfo(@"post uploaded: %@", self.apost.postTitle);
            } failure:^(NSError *error) {
                DDLogError(@"post failed: %@", [error localizedDescription]);
            }];
            [self deleteBackupPost];
        }
    }
}

- (void)dismissEditView {
#if USE_AUTOSAVES
    [self deleteBackupPost];
#endif
    [self dismissViewControllerAnimated:YES completion:nil];

	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)refreshButtons {
    
    // If we're autosaving our first post remotely, don't mess with the save button because we want it to stay disabled
    if (![self.apost hasRemote] && _isAutosaving)
        return;
    
    if (self.navigationItem.leftBarButtonItem == nil) {
        UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Cancel", nil) style:UIBarButtonItemStylePlain target:self action:@selector(cancelView:)];
        self.navigationItem.leftBarButtonItem = cancelButton;
    }

    NSString *buttonTitle;
    if(![self.apost hasRemote] || ![self.apost.status isEqualToString:self.apost.original.status]) {
        if ([self.apost.status isEqualToString:@"publish"] && ([self.apost.dateCreated compare:[NSDate date]] == NSOrderedDescending)) {
            buttonTitle = NSLocalizedString(@"Schedule", @"Schedule button, this is what the Publish button changes to in the Post Editor if the post has been scheduled for posting later.");
		} else if ([self.apost.status isEqualToString:@"publish"]){
            buttonTitle = NSLocalizedString(@"Publish", @"Publish button label.");
		} else {
            buttonTitle = NSLocalizedString(@"Save", @"Save button label (saving content, ex: Post, Page, Comment).");
        }
    } else {
        buttonTitle = NSLocalizedString(@"Update", @"Update button label (saving content, ex: Post, Page, Comment).");
    }

    if (self.navigationItem.rightBarButtonItem == nil) {
        UIBarButtonItem *saveButton = [[UIBarButtonItem alloc] initWithTitle:buttonTitle style:[WPStyleGuide barButtonStyleForDone] target:self action:@selector(saveAction:)];
        
        self.navigationItem.rightBarButtonItem = saveButton;
    } else {
        self.navigationItem.rightBarButtonItem.title = buttonTitle;
    }

    BOOL updateEnabled = self.hasChanges || self.apost.remoteStatus == AbstractPostRemoteStatusFailed;
    [self.navigationItem.rightBarButtonItem setEnabled:updateEnabled];

    // Seems to be a bug with UIBarButtonItem respecting the UIControlStateDisabled text color
    NSDictionary *titleTextAttributes;
    UIColor *color = updateEnabled ? [UIColor whiteColor] : [UIColor lightGrayColor];
    titleTextAttributes = @{NSFontAttributeName: [WPStyleGuide regularTextFont], NSForegroundColorAttributeName : color};
    [self.navigationItem.rightBarButtonItem setTitleTextAttributes:titleTextAttributes forState:UIControlStateNormal];
}

- (void)refreshUIForCurrentPost {
    self.navigationItem.title = [self editorTitle];
    
    titleTextField.text = self.apost.postTitle;
    
    if(self.apost.content == nil || [self.apost.content isEmpty]) {
        tapToStartWritingLabel.hidden = NO;
        textView.text = @"";
    } else {
        tapToStartWritingLabel.hidden = YES;
        if ((self.apost.mt_text_more != nil) && ([self.apost.mt_text_more length] > 0)) {
			textView.text = [NSString stringWithFormat:@"%@\n<!--more-->\n%@", self.apost.content, self.apost.mt_text_more];
        } else {
			textView.text = self.apost.content;
        }
    }
    
    [self refreshButtons];
}

- (void)discard {
#if USE_AUTOSAVES
    if (self.editMode == EditPostViewControllerModeEditPost) {
        [self restoreBackupPost:NO];
    }
#endif
    [self.apost.original deleteRevision];
    
	if (self.editMode == EditPostViewControllerModeNewPost) {
        [self.apost.original remove];
    }

    [self dismissEditView];
}

- (IBAction)saveAction:(id)sender {
    if (currentActionSheet.isVisible) {
        [currentActionSheet dismissWithClickedButtonIndex:-1 animated:YES];
        currentActionSheet = nil;
    }
    
	if ([self isMediaInUploading] ) {
		[self showMediaInUploadingalert];
		return;
	}
    
    if ([self hasFailedMedia]) {
        [self showFailedMediaAlert];
        return;
    }
    
    if (_isAutosaving) {
        DDLogInfo(@"Canceling all auto save operations as user is about to force a save");
        // Cancel all blog network operations since the user tapped the save/publish button
        [self.apost.blog.api cancelAllHTTPOperations];
    }
    
	[self savePost:YES];
}

- (void)savePost:(BOOL)upload{
    WPFLogMethod();
    
    [WPMobileStats trackEventForWPComWithSavedProperties:[self formattedStatEventString:StatsEventPostDetailClosedEditor]];
    
    [self logSavePostStats];

    [self.view endEditing:YES];

    [self.apost.original applyRevision];
    [self.apost.original deleteRevision];
    
    if (upload) {
        NSString *postTitle = self.apost.original.postTitle;
        [self.apost.original uploadWithSuccess:^{
            DDLogInfo(@"post uploaded: %@", postTitle);
        } failure:^(NSError *error) {
            DDLogError(@"post failed: %@", [error localizedDescription]);
        }];
    }
    
    [self dismissEditView];
}

- (void)logSavePostStats {
    NSString *buttonTitle = self.navigationItem.rightBarButtonItem.title;
    NSString *event;
    if ([buttonTitle isEqualToString:NSLocalizedString(@"Schedule", nil)]) {
        event = StatsEventPostDetailClickedSchedule;
    } else if ([buttonTitle isEqualToString:NSLocalizedString(@"Publish", nil)]) {
        event = StatsEventPostDetailClickedPublish;
    } else if ([buttonTitle isEqualToString:NSLocalizedString(@"Save", nil)]) {
        event = StatsEventPostDetailClickedSave;
    } else if ([buttonTitle isEqualToString:NSLocalizedString(@"Update", nil)]) {
        event = StatsEventPostDetailClickedUpdate;
    }
    
    if (event != nil) {
        [WPMobileStats trackEventForWPCom:[self formattedStatEventString:event]];
    }
}

- (void)autosaveContent {
    self.apost.postTitle = titleTextField.text;
    self.navigationItem.title = [self editorTitle];

    self.apost.content = textView.text;
	if ([self.apost.content rangeOfString:@"<!--more-->"].location != NSNotFound)
		self.apost.mt_text_more = @"";

    if ( self.apost.original.password != nil ) { //original post was password protected
        if ( self.apost.password == nil || [self.apost.password isEqualToString:@""] ) { //removed the password
            self.apost.password = @"";
        }
    }
    
    [self.apost save];
}

- (BOOL)canAutosaveRemotely {
#if USE_AUTOSAVES
    return ((![self.apost.original hasRemote] || [self.apost.original.status isEqualToString:@"draft"]) && self.apost.blog.reachable);
#else
    return NO;
#endif
}

- (BOOL)autosaveRemote {
    return [self autosaveRemoteWithSuccess:nil failure:nil];
}

- (BOOL)autosaveRemoteWithSuccess:(void (^)())success failure:(void (^)(NSError *error))failure {
    if (![self canAutosaveRemotely]) {
        return NO;
    }
    if (_isAutosaving) {
        return NO;
    }

    if (![self.apost.original hasRemote]) {
        _isAutosaved = YES;
    }
    [self.apost.original applyRevision];
    self.apost.original.status = @"draft";
    AbstractPostRemoteStatus currentRemoteStatus = self.apost.original.remoteStatus;
    _isAutosaving = YES;
    _hasChangesToAutosave = NO;
    if (![self.apost hasRemote]) {
        // If this is the first remote autosave for a post, disable the Publish button for safety's sake
        [self.navigationItem.rightBarButtonItem setEnabled:NO];
    }
    [self showAutosaveIndicator];
    __weak AbstractPost *originalPost = self.apost.original;
    [self.apost.original uploadWithSuccess:^{
        if (originalPost.revision == nil) {
            // If the post has been published or dismissed while autosaving
            // the network request should have been canceled
            // But just in case, don't try updating this post
            DDLogInfo(@"!!! Autosave returned after post editor was dismissed");
            _isAutosaving = NO;
            [self hideAutosaveIndicatorWithSuccess:YES];
            return;
        }
        NSString *status = self.apost.status;
        [self.apost updateRevision];
        self.apost.status = status;
        _isAutosaving = NO;
        [self hideAutosaveIndicatorWithSuccess:YES];
        [self.navigationItem.rightBarButtonItem setEnabled:YES];
        if (success) success();
        [[NSNotificationCenter defaultCenter] postNotificationName:EditPostViewControllerDidAutosaveNotification object:self];
    } failure:^(NSError *error) {
        // Restore current remote status so failed autosaves don't make the post appear as failed
        // Specially useful when offline
        originalPost.remoteStatus = currentRemoteStatus;
        _isAutosaving = NO;
        _hasChangesToAutosave = YES;
        [self hideAutosaveIndicatorWithSuccess:NO];
        [self.navigationItem.rightBarButtonItem setEnabled:YES];
        [[NSNotificationCenter defaultCenter] postNotificationName:EditPostViewControllerAutosaveDidFailNotification object:self userInfo:@{@"error": error}];
    }];

    return YES;
}

- (void)incrementCharactersChangedForAutosaveBy:(NSUInteger)change {
    _charactersChanged += change;
    if (_charactersChanged > [self autosaveCharactersChangedThreshold]) {
        _charactersChanged = 0;
        double delayInSeconds = 0.2;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self autosaveRemote];
        });
    }
}

- (void)showAutosaveIndicator {
    [_autosavingIndicatorView startAnimating];
}

- (void)hideAutosaveIndicatorWithSuccess:(BOOL)success {
    [_autosavingIndicatorView stopAnimatingWithSuccess:success];
}

- (NSUInteger)autosaveCharactersChangedThreshold {
    if ([self.apost.blog.reachability isReachableViaWWAN]) {
        return EditPostViewControllerCharactersChangedToAutosaveOnWWAN;
    } else {
        return EditPostViewControllerCharactersChangedToAutosave;
    }
}

- (BOOL)hasFailedMedia {
	BOOL hasFailedMedia = NO;

	NSSet *mediaFiles = self.apost.media;
	for (Media *media in mediaFiles) {
		if(media.remoteStatus == MediaRemoteStatusFailed) {
			hasFailedMedia = YES;
			break;
		}
	}
	mediaFiles = nil;

	return hasFailedMedia;
}

//check if there are media in uploading status
- (BOOL)isMediaInUploading {
	BOOL isMediaInUploading = NO;
	
	NSSet *mediaFiles = self.apost.media;
	for (Media *media in mediaFiles) {
		if(media.remoteStatus == MediaRemoteStatusPushing) {
			isMediaInUploading = YES;
			break;
		}
	}
	mediaFiles = nil;

	return isMediaInUploading;
}

- (void)showFailedMediaAlert {
    if (_failedMediaAlertView)
        return;
    _failedMediaAlertView = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Pending media", @"Title for alert when trying to publish a post with failed media items")
                                                       message:NSLocalizedString(@"There are media items in this post that aren't uploaded to the server. Do you want to continue?", @"")
                                                      delegate:self
                                             cancelButtonTitle:NSLocalizedString(@"No", @"")
                                             otherButtonTitles:NSLocalizedString(@"Post anyway", @""), nil];
    _failedMediaAlertView.tag = EditPostViewControllerAlertTagFailedMedia;
    [_failedMediaAlertView show];
}

- (void)showMediaInUploadingalert {
	//the post is using the network connection and cannot be stoped, show a message to the user
	UIAlertView *blogIsCurrentlyBusy = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Info", @"Info alert title")
																  message:NSLocalizedString(@"A Media file is currently uploading. Please try later.", @"")
																 delegate:nil cancelButtonTitle:NSLocalizedString(@"OK", @"") otherButtonTitles:nil];
	[blogIsCurrentlyBusy show];
}

- (IBAction)cancelView:(id)sender {
    if(currentActionSheet) return;
    
    [textView resignFirstResponder];
    [titleTextField resignFirstResponder];
	[self.postSettingsViewController endEditingAction:nil];
#if USE_AUTOSAVES
    [self restoreBackupPost:YES];
#endif
	if ([self isMediaInUploading]) {
		[self showMediaInUploadingalert];
		return;
	}

    if (![self hasChanges]) {
        [WPMobileStats trackEventForWPComWithSavedProperties:[self formattedStatEventString:StatsEventPostDetailClosedEditor]];
        [self discard];
        return;
    }

	UIActionSheet *actionSheet;
	if (![self.apost.original.status isEqualToString:@"draft"] && self.editMode != EditPostViewControllerModeNewPost) {
        // The post is already published in the server or it was intended to be and failed: Discard changes or keep editing
		actionSheet = [[UIActionSheet alloc] initWithTitle:NSLocalizedString(@"You have unsaved changes.", @"Title of message with options that shown when there are unsaved changes and the author is trying to move away from the post.")
												  delegate:self
                                         cancelButtonTitle:NSLocalizedString(@"Keep Editing", @"Button shown if there are unsaved changes and the author is trying to move away from the post.")
                                    destructiveButtonTitle:NSLocalizedString(@"Discard", @"Button shown if there are unsaved changes and the author is trying to move away from the post.")
										 otherButtonTitles:nil];
    } else if (self.editMode == EditPostViewControllerModeNewPost) {
        // The post is a local draft or an autosaved draft: Discard or Save
        actionSheet = [[UIActionSheet alloc] initWithTitle:NSLocalizedString(@"You have unsaved changes.", @"Title of message with options that shown when there are unsaved changes and the author is trying to move away from the post.")
                                                  delegate:self
                                         cancelButtonTitle:NSLocalizedString(@"Keep Editing", @"Button shown if there are unsaved changes and the author is trying to move away from the post.")
                                    destructiveButtonTitle:NSLocalizedString(@"Discard", @"Button shown if there are unsaved changes and the author is trying to move away from the post.")
                                         otherButtonTitles:NSLocalizedString(@"Save Draft", @"Button shown if there are unsaved changes and the author is trying to move away from the post."), nil];
    } else {
        // The post was already a draft
        actionSheet = [[UIActionSheet alloc] initWithTitle:NSLocalizedString(@"You have unsaved changes.", @"Title of message with options that shown when there are unsaved changes and the author is trying to move away from the post.")
                                                  delegate:self
                                         cancelButtonTitle:NSLocalizedString(@"Keep Editing", @"Button shown if there are unsaved changes and the author is trying to move away from the post.")
                                    destructiveButtonTitle:NSLocalizedString(@"Discard", @"Button shown if there are unsaved changes and the author is trying to move away from the post.")
                                         otherButtonTitles:NSLocalizedString(@"Update Draft", @"Button shown if there are unsaved changes and the author is trying to move away from an already published/saved post."), nil];
    }
    
    actionSheet.tag = 201;
    actionSheet.actionSheetStyle = UIActionSheetStyleAutomatic;
    if (IS_IPAD) {
        [actionSheet showFromBarButtonItem:self.navigationItem.leftBarButtonItem animated:YES];
    } else {
        [actionSheet showInView:self.view];
    }

    WordPressAppDelegate *appDelegate = (WordPressAppDelegate *)[[UIApplication sharedApplication] delegate];
    [appDelegate setAlertRunning:YES];
    
}

//code to append http:// if protocol part is not there as part of urlText.
- (NSString *)validateNewLinkInfo:(NSString *)urlText {
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[\\w]+:" options:0 error:&error];

    if ([regex numberOfMatchesInString:urlText options:0 range:NSMakeRange(0, [urlText length])] > 0) {
        return urlText;
    } else if([urlText hasPrefix:@"#"]) {
        // link to named anchor
        return urlText;
    } else {
        return [NSString stringWithFormat:@"http://%@", urlText];
    }
}

- (void)showLinkView {
    if (_linkHelperAlertView) {
        [_linkHelperAlertView dismiss];
        _linkHelperAlertView = nil;
    }
    
    NSRange range = textView.selectedRange;
    NSString *infoText = nil;
    
    if (range.length > 0)
        infoText = [textView.text substringWithRange:range];

    _linkHelperAlertView = [[WPAlertView alloc] initWithFrame:self.view.bounds andOverlayMode:WPAlertViewOverlayModeTwoTextFieldsTwoButtonMode];
    
    NSString *title = NSLocalizedString(@"Make a Link\n\n\n\n", @"Title of the Link Helper popup to aid in creating a Link in the Post Editor.\n\n\n\n");
    NSCharacterSet *charSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    title = [title stringByTrimmingCharactersInSet:charSet];
    
    _linkHelperAlertView.overlayTitle = title;
    _linkHelperAlertView.overlayDescription = @"";
    _linkHelperAlertView.footerDescription = [NSLocalizedString(@"tap to dismiss", nil) uppercaseString];
    _linkHelperAlertView.firstTextFieldPlaceholder = NSLocalizedString(@"Text to be linked", @"Popup to aid in creating a Link in the Post Editor.");
    _linkHelperAlertView.firstTextFieldValue = infoText;
    _linkHelperAlertView.secondTextFieldPlaceholder = NSLocalizedString(@"Link URL", @"Popup to aid in creating a Link in the Post Editor, URL field (where you can type or paste a URL that the text should link.");
    _linkHelperAlertView.leftButtonText = NSLocalizedString(@"Cancel", @"Cancel button");
    _linkHelperAlertView.rightButtonText = NSLocalizedString(@"Insert", @"Insert content (link, media) button");
    
    _linkHelperAlertView.firstTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _linkHelperAlertView.secondTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _linkHelperAlertView.firstTextField.keyboardAppearance = UIKeyboardAppearanceAlert;
    _linkHelperAlertView.secondTextField.keyboardAppearance = UIKeyboardAppearanceAlert;
    _linkHelperAlertView.firstTextField.keyboardType = UIKeyboardTypeDefault;
    _linkHelperAlertView.secondTextField.keyboardType = UIKeyboardTypeURL;
    _linkHelperAlertView.secondTextField.autocorrectionType = UITextAutocorrectionTypeNo;

    if (UIInterfaceOrientationIsLandscape(self.interfaceOrientation) && IS_IPHONE && !isExternalKeyboard) {
        [_linkHelperAlertView hideTitleAndDescription:YES];
    }
    
    __block UITextView *editorTextView = textView;
    __block id fles = self;
    _linkHelperAlertView.button1CompletionBlock = ^(WPAlertView *overlayView){
        // Cancel
        [overlayView dismiss];
        
        WordPressAppDelegate *delegate = (WordPressAppDelegate*)[[UIApplication sharedApplication] delegate];
        [delegate setAlertRunning:NO];
        [editorTextView becomeFirstResponder];
        
        [fles setLinkHelperAlertView:nil];
    };
    _linkHelperAlertView.button2CompletionBlock = ^(WPAlertView *overlayView){
        WordPressAppDelegate *delegate = (WordPressAppDelegate*)[[UIApplication sharedApplication] delegate];

        // Insert
        
        //Disable scrolling temporarily otherwise inserting text will scroll to the bottom in iOS6 and below.
        editorTextView.scrollEnabled = NO;
        [overlayView dismiss];
        
        [editorTextView becomeFirstResponder];

        UITextField *infoText = overlayView.firstTextField;
        UITextField *urlField = overlayView.secondTextField;

        if ((urlField.text == nil) || ([urlField.text isEqualToString:@""])) {
            [delegate setAlertRunning:NO];
            return;
        }
        
        if ((infoText.text == nil) || ([infoText.text isEqualToString:@""]))
            infoText.text = urlField.text;
        
        NSString *urlString = [fles validateNewLinkInfo:[urlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        NSString *aTagText = [NSString stringWithFormat:@"<a href=\"%@\">%@</a>", urlString, infoText.text];
        
        NSRange range = editorTextView.selectedRange;
        
        NSString *oldText = editorTextView.text;
        NSRange oldRange = editorTextView.selectedRange;
        editorTextView.text = [editorTextView.text stringByReplacingCharactersInRange:range withString:aTagText];
        
        //Re-enable scrolling after insertion is complete
        editorTextView.scrollEnabled = YES;
        
        //reset selection back to nothing
        range.length = 0;
        
        if (range.length == 0) {                // If nothing was selected
            range.location += [aTagText length]; // Place selection between tags
            editorTextView.selectedRange = range;
        }
        [[editorTextView.undoManager prepareWithInvocationTarget:fles] restoreText:oldText withRange:oldRange];
        [editorTextView.undoManager setActionName:@"link"];
        
        [fles setHasChangesToAutosave:YES];
        [fles autosaveContent];
        [fles incrementCharactersChangedForAutosaveBy:MAX(oldRange.length, aTagText.length)];
        
        [delegate setAlertRunning:NO];
        [fles setLinkHelperAlertView:nil];
        [fles refreshTextView];
    };
    
    _linkHelperAlertView.alpha = 0.0;
    [self.view addSubview:_linkHelperAlertView];
    if ([infoText length] > 0) {
        [_linkHelperAlertView.secondTextField becomeFirstResponder];
    }
    [UIView animateWithDuration:0.2 animations:^{
        _linkHelperAlertView.alpha = 1.0;
    }];
}

- (BOOL)hasChanges {
    return [self.apost hasChanged];
}

#pragma mark -
#pragma mark AlertView Delegate Methods

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == EditPostViewControllerAlertTagFailedMedia) {
        if (buttonIndex == 1) {
            DDLogInfo(@"Saving post even after some media failed to upload");
            [self savePost:YES];
        }
        _failedMediaAlertView = nil;
    }
	
    return;
}


#pragma mark -
#pragma mark ActionSheet Delegate Methods

- (void)willPresentActionSheet:(UIActionSheet *)actionSheet {
    currentActionSheet = actionSheet;
}

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex {
    currentActionSheet = nil;
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if ([actionSheet tag] == 201) {
        // Discard
        if (buttonIndex == 0) {
            [WPMobileStats trackEventForWPComWithSavedProperties:[self formattedStatEventString:StatsEventPostDetailClosedEditor]];
            [self discard];
        }

        if (buttonIndex == 1) {
            // Cancel / Keep editing
			if ([actionSheet numberOfButtons] == 2) {
                [WPMobileStats trackEventForWPComWithSavedProperties:[self formattedStatEventString:StatsEventPostDetailClosedEditor]];
                
				[actionSheet dismissWithClickedButtonIndex:0 animated:YES];
            // Save draft
			} else {
                [WPMobileStats trackEventForWPComWithSavedProperties:[self formattedStatEventString:StatsEventPostDetailClosedEditor]];
                
                // If you tapped on a button labeled "Save Draft", you probably expect the post to be saved as a draft
                if ((![self.apost hasRemote] || _isAutosaved) && [self.apost.status isEqualToString:@"publish"]) {
                    self.apost.status = @"draft";
                }
                DDLogInfo(@"Saving post as a draft after user initially attempted to cancel");
                [self savePost:YES];
			}
        }
    }
    
    WordPressAppDelegate *appDelegate = (WordPressAppDelegate *)[[UIApplication sharedApplication] delegate];
    [appDelegate setAlertRunning:NO];
}

#pragma mark - TextView delegate

- (void)textViewDidBeginEditing:(UITextView *)aTextView {
    WPFLogMethod();
    [tapToStartWritingLabel removeFromSuperview];
}

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    [self incrementCharactersChangedForAutosaveBy:MAX(range.length, text.length)];
    return YES;
}

- (void)textViewDidChange:(UITextView *)aTextView {
    _hasChangesToAutosave = YES;
    [self autosaveContent];

    [self refreshButtons];
}

- (void)textViewDidEndEditing:(UITextView *)aTextView {
    WPFLogMethod();
	
	if([textView.text isEqualToString:@""]) {
        [self.view addSubview:tapToStartWritingLabel];
	}
	
    _hasChangesToAutosave = YES;
    [self autosaveContent];
    [self autosaveRemote];

    [self refreshButtons];
}

#pragma mark - TextField delegate

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    currentEditingTextField = textField;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    currentEditingTextField = nil;
    _hasChangesToAutosave = YES;
    [self autosaveContent];
    [self autosaveRemote];
    [self refreshButtons];
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    if (textField == titleTextField) {
        self.apost.postTitle = [textField.text stringByReplacingCharactersInRange:range withString:string];
        self.navigationItem.title = [self editorTitle];
    }

    _hasChangesToAutosave = YES;
    [self refreshButtons];
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    currentEditingTextField = nil;
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Positioning & Rotation

- (BOOL)wantsFullScreen {
    /*
     "Full screen" mode for:
     * iPhone Portrait without external keyboard
     * iPhone Landscape
     * iPad Landscape without external keyboard
     
     Show other fields:
     * iPhone Portrait with external keyboard
     * iPad Portrait
     * iPad Landscape with external keyboard
     */
    BOOL isLandscape = UIInterfaceOrientationIsLandscape([UIApplication sharedApplication].statusBarOrientation);
    BOOL yesOrNo = (
                    (!IS_IPAD && !isExternalKeyboard)                  // iPhone without external keyboard
                    || (!IS_IPAD && isLandscape && isExternalKeyboard) // iPhone Landscape with external keyboard
                    || (IS_IPAD && isLandscape && !isExternalKeyboard) // iPad Landscape without external keyboard
                    );
    return yesOrNo;
}

- (void)positionTextView:(NSNotification *)notification {
    // Save time: Uncomment this line when you're debugging UITextView positioning
    // textView.backgroundColor = [UIColor blueColor];

    NSDictionary *keyboardInfo = [notification userInfo];

	CGFloat animationDuration = 0.3;
	UIViewAnimationCurve curve = 0.3;
	[UIView beginAnimations:nil context:nil];
	[UIView setAnimationCurve:curve];
	[UIView setAnimationDuration:animationDuration];

    CGRect newFrame = [self normalTextFrame];
	if(keyboardInfo != nil) {
		animationDuration = [[keyboardInfo objectForKey:UIKeyboardAnimationDurationUserInfoKey] floatValue];
		curve = [[keyboardInfo objectForKey:UIKeyboardAnimationCurveUserInfoKey] floatValue];
        [UIView setAnimationCurve:curve];
        [UIView setAnimationDuration:animationDuration];

        CGRect originalKeyboardFrame = [[keyboardInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
        CGRect keyboardFrame = [self.view convertRect:[self.view.window convertRect:originalKeyboardFrame fromWindow:nil] fromView:nil];
        
        newFrame = [self normalTextFrame];

        if (isShowingKeyboard) {

            if ([self wantsFullScreen]) {
                // Make the text view expand covering other fields
                newFrame.origin.x = 0;
                newFrame.origin.y = 0;
                newFrame.size.width = self.view.frame.size.width;
            }
            // Adjust height for keyboard (or format bar on external keyboard)
            newFrame.size.height = keyboardFrame.origin.y - newFrame.origin.y;

            [self.toolbar setHidden:YES];
            separatorView.hidden = YES;
        } else {
            [self.toolbar setHidden:NO];
            separatorView.hidden = NO;
        }
	}

    [textView setFrame:newFrame];
	
	[UIView commitAnimations];
}

- (void)positionAutosaveView:(NSNotification *)notification {
    CGRect frame;
    frame.size.width = 80.f;
    frame.size.height = 20.f;
    frame.origin.x = CGRectGetMaxX(textView.frame) - 4.f - frame.size.width;
    frame.origin.y = CGRectGetMaxY(textView.frame) - 4.f - frame.size.height;

    NSDictionary *keyboardInfo = [notification userInfo];
    if (keyboardInfo) {
        CGRect originalKeyboardFrame = [[keyboardInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
        CGRect keyboardFrame = [self.view convertRect:[self.view.window convertRect:originalKeyboardFrame fromWindow:nil] fromView:nil];
        if (CGRectGetMinY(keyboardFrame) < CGRectGetMaxY(frame)) {
            // Keyboard would cover the indicator, reposition
            frame.origin.y = CGRectGetMinY(keyboardFrame) - 4.f - frame.size.height;
        }
    }

    _autosavingIndicatorView.frame = frame;
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation duration:(NSTimeInterval)duration {
    WPFLogMethod();
    CGRect frame = editorToolbar.frame;
    if (UIDeviceOrientationIsLandscape(interfaceOrientation)) {
        if (IS_IPAD) {
            frame.size.height = WPKT_HEIGHT_IPAD_LANDSCAPE;
        } else {
            frame.size.height = WPKT_HEIGHT_IPHONE_LANDSCAPE;
            if (_linkHelperAlertView && !isExternalKeyboard) {
                [_linkHelperAlertView hideTitleAndDescription:YES];
            }
        }
        
    } else {
        if (IS_IPAD) {
            frame.size.height = WPKT_HEIGHT_IPAD_PORTRAIT;
        } else {
            frame.size.height = WPKT_HEIGHT_IPHONE_PORTRAIT;
            if (_linkHelperAlertView) {
                [_linkHelperAlertView hideTitleAndDescription:NO];
            }
        }
    }
    editorToolbar.frame = frame;

}

#pragma mark - Media management

- (void)insertMediaAbove:(NSNotification *)notification {
    [WPMobileStats trackEventForWPCom:[self formattedStatEventString:StatsEventPostDetailAddedPhoto]];
    
	Media *media = (Media *)[notification object];
	NSString *prefix = @"<br /><br />";
	
	if(self.apost.content == nil || [self.apost.content isEqualToString:@""]) {
		self.apost.content = @"";
		prefix = @"";
	}
	
	NSMutableString *content = [[NSMutableString alloc] initWithString:media.html];
	NSRange imgHTML = [textView.text rangeOfString: content];
	
	NSRange imgHTMLPre = [textView.text rangeOfString:[NSString stringWithFormat:@"%@%@", @"<br /><br />", content]]; 
 	NSRange imgHTMLPost = [textView.text rangeOfString:[NSString stringWithFormat:@"%@%@", content, @"<br /><br />"]]; 
	
	if (imgHTMLPre.location == NSNotFound && imgHTMLPost.location == NSNotFound && imgHTML.location == NSNotFound) {
		[content appendString:[NSString stringWithFormat:@"%@%@", prefix, self.apost.content]];
        self.apost.content = content;
	}
	else { 
		NSMutableString *processedText = [[NSMutableString alloc] initWithString:textView.text]; 
		if (imgHTMLPre.location != NSNotFound) 
			[processedText replaceCharactersInRange:imgHTMLPre withString:@""];
		else if (imgHTMLPost.location != NSNotFound) 
			[processedText replaceCharactersInRange:imgHTMLPost withString:@""];
		else  
			[processedText replaceCharactersInRange:imgHTML withString:@""];  
		 
		[content appendString:[NSString stringWithFormat:@"<br /><br />%@", processedText]]; 
		self.apost.content = content;
	}
    _hasChangesToAutosave = YES;
    [self refreshUIForCurrentPost];
    [self.apost save];
    [self incrementCharactersChangedForAutosaveBy:content.length];
}

- (void)insertMediaBelow:(NSNotification *)notification {
    [WPMobileStats trackEventForWPCom:[self formattedStatEventString:StatsEventPostDetailAddedPhoto]];
    
	Media *media = (Media *)[notification object];
	NSString *prefix = @"<br /><br />";
	
	if(self.apost.content == nil || [self.apost.content isEqualToString:@""]) {
		self.apost.content = @"";
		prefix = @"";
	}
	
	NSMutableString *content = [[NSMutableString alloc] initWithString:self.apost.content];
	NSRange imgHTML = [content rangeOfString: media.html];
	NSRange imgHTMLPre = [content rangeOfString:[NSString stringWithFormat:@"%@%@", @"<br /><br />", media.html]]; 
 	NSRange imgHTMLPost = [content rangeOfString:[NSString stringWithFormat:@"%@%@", media.html, @"<br /><br />"]];
	
	if (imgHTMLPre.location == NSNotFound && imgHTMLPost.location == NSNotFound && imgHTML.location == NSNotFound) {
		[content appendString:[NSString stringWithFormat:@"%@%@", prefix, media.html]];
        self.apost.content = content;
	}
	else {
		if (imgHTMLPre.location != NSNotFound) 
			[content replaceCharactersInRange:imgHTMLPre withString:@""]; 
		else if (imgHTMLPost.location != NSNotFound) 
			[content replaceCharactersInRange:imgHTMLPost withString:@""];
		else  
			[content replaceCharactersInRange:imgHTML withString:@""];
		[content appendString:[NSString stringWithFormat:@"<br /><br />%@", media.html]];
		self.apost.content = content;
	}
    _hasChangesToAutosave = YES;
    [self refreshUIForCurrentPost];
    [self.apost save];
    [self incrementCharactersChangedForAutosaveBy:content.length];
}

- (void)removeMedia:(NSNotification *)notification {
    [WPMobileStats trackEventForWPCom:[self formattedStatEventString:StatsEventPostDetailRemovedPhoto]];

	//remove the html string for the media object
	Media *media = (Media *)[notification object];
	textView.text = [textView.text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"<br /><br />%@", media.html] withString:@""];
	textView.text = [textView.text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%@<br /><br />", media.html] withString:@""];
	textView.text = [textView.text stringByReplacingOccurrencesOfString:media.html withString:@""];
    _hasChangesToAutosave = YES;
    [self autosaveContent];
    [self refreshUIForCurrentPost];
    [self incrementCharactersChangedForAutosaveBy:media.html.length];
}


#pragma mark - Keyboard toolbar

- (void)undo {
    [textView.undoManager undo];
    _hasChangesToAutosave = YES;
    [self autosaveContent];
}

- (void)redo {
    [textView.undoManager redo];
    _hasChangesToAutosave = YES;
    [self autosaveContent];
}

- (void)restoreText:(NSString *)text withRange:(NSRange)range {
    DDLogVerbose(@"restoreText:%@",text);
    NSString *oldText = textView.text;
    NSRange oldRange = textView.selectedRange;
    textView.scrollEnabled = NO;
    // iOS6 seems to have a bug where setting the text like so : textView.text = text;
    // will cause an infinate loop of undos.  A work around is to perform the selector
    // on the main thread.
    // textView.text = text;
    [textView performSelectorOnMainThread:@selector(setText:) withObject:text waitUntilDone:NO];
    textView.scrollEnabled = YES;
    textView.selectedRange = range;
    [[textView.undoManager prepareWithInvocationTarget:self] restoreText:oldText withRange:oldRange];
    _hasChangesToAutosave = YES;
    [self autosaveContent];
    [self incrementCharactersChangedForAutosaveBy:MAX(text.length, range.length)];
}

- (void)wrapSelectionWithTag:(NSString *)tag {
    NSRange range = textView.selectedRange;
    NSRange originalRange = range;
    NSString *selection = [textView.text substringWithRange:range];
    NSString *prefix, *suffix;
    if ([tag isEqualToString:@"ul"] || [tag isEqualToString:@"ol"]) {
        prefix = [NSString stringWithFormat:@"<%@>\n", tag];
        suffix = [NSString stringWithFormat:@"\n</%@>\n", tag];
    } else if ([tag isEqualToString:@"li"]) {
        prefix = [NSString stringWithFormat:@"\t<%@>", tag];
        suffix = [NSString stringWithFormat:@"</%@>\n", tag];
    } else if ([tag isEqualToString:@"more"]) {
        prefix = @"<!--more-->";
        suffix = @"\n";
    } else if ([tag isEqualToString:@"blockquote"]) {
        prefix = [NSString stringWithFormat:@"\n<%@>", tag];
        suffix = [NSString stringWithFormat:@"</%@>\n", tag];
    } else {
        prefix = [NSString stringWithFormat:@"<%@>", tag];
        suffix = [NSString stringWithFormat:@"</%@>", tag];        
    }
    textView.scrollEnabled = NO;
    NSString *replacement = [NSString stringWithFormat:@"%@%@%@",prefix,selection,suffix];
    textView.text = [textView.text stringByReplacingCharactersInRange:range
                                                           withString:replacement];
    textView.scrollEnabled = YES;
    if (range.length == 0) {                // If nothing was selected
        range.location += [prefix length]; // Place selection between tags
    } else {
        range.location += range.length + [prefix length] + [suffix length]; // Place selection after tag
        range.length = 0;
    }
    textView.selectedRange = range;
    _hasChangesToAutosave = YES;
    [self autosaveContent];
    [self incrementCharactersChangedForAutosaveBy:MAX(replacement.length, originalRange.length)];
    [self refreshTextView];
}

// In some situations on iOS7, inserting text while `scrollEnabled = NO` results in
// the last line(s) of text on the text view not appearing. This is a workaround
// to get the UITextView to redraw after inserting text but without affecting the
// scrollOffset.
- (void)refreshTextView {
    dispatch_async(dispatch_get_main_queue(), ^{
        textView.scrollEnabled = NO;
        [textView setNeedsDisplay];
        textView.scrollEnabled = YES;
    });
}

- (void)keyboardToolbarButtonItemPressed:(WPKeyboardToolbarButtonItem *)buttonItem {
    WPFLogMethod();
    [self logWPKeyboardToolbarButtonStat:buttonItem];
    if ([buttonItem.actionTag isEqualToString:@"link"]) {
        [self showLinkView];
    } else if ([buttonItem.actionTag isEqualToString:@"done"]) {
        [textView resignFirstResponder];
    } else {
        NSString *oldText = textView.text;
        NSRange oldRange = textView.selectedRange;
        [self wrapSelectionWithTag:buttonItem.actionTag];
        [[textView.undoManager prepareWithInvocationTarget:self] restoreText:oldText withRange:oldRange];
        [textView.undoManager setActionName:buttonItem.actionName];    
    }
}

- (void)logWPKeyboardToolbarButtonStat:(WPKeyboardToolbarButtonItem *)buttonItem {
    NSString *actionTag = buttonItem.actionTag;
    NSString *property;
    if ([actionTag isEqualToString:@"strong"]) {
        property = StatsEventPostDetailClickedKeyboardToolbarBoldButton;
    } else if ([actionTag isEqualToString:@"em"]) {
        property = StatsEventPostDetailClickedKeyboardToolbarItalicButton;
    } else if ([actionTag isEqualToString:@"link"]) {
        property = StatsEventPostDetailClickedKeyboardToolbarLinkButton;
    } else if ([actionTag isEqualToString:@"blockquote"]) {
        property = StatsEventPostDetailClickedKeyboardToolbarBlockquoteButton;
    } else if ([actionTag isEqualToString:@"del"]) {
        property = StatsEventPostDetailClickedKeyboardToolbarDelButton;
    } else if ([actionTag isEqualToString:@"ul"]) {
        property = StatsEventPostDetailClickedKeyboardToolbarUnorderedListButton;
    } else if ([actionTag isEqualToString:@"ol"]) {
        property = StatsEventPostDetailClickedKeyboardToolbarOrderedListButton;
    } else if ([actionTag isEqualToString:@"li"]) {
        property = StatsEventPostDetailClickedKeyboardToolbarListItemButton;
    } else if ([actionTag isEqualToString:@"code"]) {
        property = StatsEventPostDetailClickedKeyboardToolbarCodeButton;
    } else if ([actionTag isEqualToString:@"more"]) {
        property = StatsEventPostDetailClickedKeyboardToolbarMoreButton;
    }
    
    if (property != nil) {
        [WPMobileStats flagProperty:property forEvent:[self formattedStatEventString:StatsEventPostDetailClosedEditor]];
    }
}

#pragma mark -
#pragma mark Keyboard management 

- (void)keyboardWillShow:(NSNotification *)notification {
    WPFLogMethod();
	isShowingKeyboard = YES;
    
    CGRect originalKeyboardFrame = [[[notification userInfo] objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardFrame = [self.view convertRect:[self.view.window convertRect:originalKeyboardFrame fromWindow:nil] fromView:nil];
    isExternalKeyboard = keyboardFrame.origin.y + keyboardFrame.size.height > self.view.bounds.size.height;

    if ([textView isFirstResponder] || self.linkHelperAlertView.firstTextField.isFirstResponder || self.linkHelperAlertView.secondTextField.isFirstResponder) {
        [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade];
        if ([self wantsFullScreen]) {
            [self.navigationController setNavigationBarHidden:YES animated:YES];
        }
    }
    if ([textView isFirstResponder]) {
        [self positionTextView:notification];
        editorToolbar.doneButton.hidden = IS_IPAD && ! isExternalKeyboard;
    }
    [self positionAutosaveView:notification];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    WPFLogMethod();
	isShowingKeyboard = NO;
    [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationFade];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
    
    [self positionTextView:notification];
    [self positionAutosaveView:notification];
}

#pragma mark -
#pragma mark Memory management

- (void)didReceiveMemoryWarning {
    WPFLogMethod();
    [super didReceiveMemoryWarning];
}

@end
