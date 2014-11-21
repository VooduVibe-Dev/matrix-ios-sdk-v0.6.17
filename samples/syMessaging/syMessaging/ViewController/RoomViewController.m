/*
 Copyright 2014 OpenMarket Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */
#import <MobileCoreServices/MobileCoreServices.h>

#import <MediaPlayer/MediaPlayer.h>

#import "RoomViewController.h"
#import "RoomMessageTableCell.h"
#import "RoomMemberTableCell.h"

#import "MatrixHandler.h"
#import "AppDelegate.h"
#import "AppSettings.h"

#import "MediaManager.h"

#define UPLOAD_FILE_SIZE 5000000

#define ROOM_MESSAGE_CELL_MAX_TEXTVIEW_WIDTH 200

#define ROOM_MESSAGE_CELL_TEXTVIEW_TOP_CONST_DEFAULT 10
#define ROOM_MESSAGE_CELL_TEXTVIEW_TOP_CONST_IN_CHUNK (-5)
#define ROOM_MESSAGE_CELL_TEXTVIEW_EDGE_INSET_TOP_IN_CHUNK ROOM_MESSAGE_CELL_TEXTVIEW_TOP_CONST_IN_CHUNK
#define ROOM_MESSAGE_CELL_TEXTVIEW_BOTTOM_CONST_DEFAULT 0
#define ROOM_MESSAGE_CELL_TEXTVIEW_BOTTOM_CONST_GROUPED_CELL (-5)

#define ROOM_MESSAGE_CELL_IMAGE_MARGIN 8

NSString *const kCmdChangeDisplayName = @"/nick";
NSString *const kCmdEmote = @"/me";
NSString *const kCmdJoinRoom = @"/join";
NSString *const kCmdKickUser = @"/kick";
NSString *const kCmdBanUser = @"/ban";
NSString *const kCmdUnbanUser = @"/unban";
NSString *const kCmdSetUserPowerLevel = @"/op";
NSString *const kCmdResetUserPowerLevel = @"/deop";

NSString *const kLocalEchoEventIdPrefix = @"localEcho-";
NSString *const kFailedEventId = @"failedEventId";


@interface RoomViewController () {
    BOOL forceScrollToBottomOnViewDidAppear;
    BOOL isJoinRequestInProgress;
    
    MXRoom *mxRoom;

    // Messages
    NSMutableArray *messages;
    id messagesListener;
    NSString *mostRecentEventIdOnViewWillDisappear;
    
    // Back pagination
    BOOL isBackPaginationInProgress;
    NSUInteger backPaginationAddedItemsNb;
    
    // Members list
    NSArray *members;
    id membersListener;
    
    // Attachment handling
    CustomImageView *highResImage;
    NSString *AVAudioSessionCategory;
    MPMoviePlayerController *videoPlayer;
    
    // Date formatter (nil if dateTimeLabel is hidden)
    NSDateFormatter *dateFormatter;
    
    // Text view settings
    NSAttributedString *initialAttributedStringForOutgoingMessage;
    NSAttributedString *initialAttributedStringForIncomingMessage;
    
    // Cache
    NSMutableArray *tmpCachedAttachments;
}

@property (weak, nonatomic) IBOutlet UINavigationItem *roomNavItem;
@property (weak, nonatomic) IBOutlet UITextField *roomNameTextField;
@property (weak, nonatomic) IBOutlet UITableView *messagesTableView;
@property (weak, nonatomic) IBOutlet UIView *controlView;
@property (weak, nonatomic) IBOutlet UIButton *optionBtn;
@property (weak, nonatomic) IBOutlet UITextField *messageTextField;
@property (weak, nonatomic) IBOutlet UIButton *sendBtn;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *controlViewBottomConstraint;
@property (weak, nonatomic) IBOutlet UIActivityIndicatorView *activityIndicator;
@property (weak, nonatomic) IBOutlet UIView *membersView;
@property (weak, nonatomic) IBOutlet UITableView *membersTableView;

@property (strong, nonatomic) CustomAlert *actionMenu;
@end

@implementation RoomViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    forceScrollToBottomOnViewDidAppear = YES;
    mostRecentEventIdOnViewWillDisappear = nil;
    
    UIButton *button = [UIButton buttonWithType:UIButtonTypeInfoLight];
    [button addTarget:self action:@selector(showHideRoomMembers:) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:button];
    
    // Add tap detection on members view in order to hide members when the user taps outside members list
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideRoomMembers)];
    [tap setNumberOfTouchesRequired:1];
    [tap setNumberOfTapsRequired:1];
    [tap setDelegate:self];
    [self.membersView addGestureRecognizer:tap];
    
    _sendBtn.enabled = NO;
    _sendBtn.alpha = 0.5;
}

- (void)dealloc {
    // Clear temporary cached attachments (used for local echo)
    NSUInteger index = tmpCachedAttachments.count;
    NSError *error = nil;
    while (index--) {
        if (![[NSFileManager defaultManager] removeItemAtPath:[tmpCachedAttachments objectAtIndex:index] error:&error]) {
            NSLog(@"Fail to delete cached media: %@", error);
        }
    }
    tmpCachedAttachments = nil;
    
    [self hideAttachmentView];
    
    messages = nil;
    if (messagesListener) {
        [mxRoom removeListener:messagesListener];
        messagesListener = nil;
    }
    mxRoom = nil;
    
    members = nil;
    if (membersListener) {
        membersListener = nil;
    }
    
    if (self.actionMenu) {
        [self.actionMenu dismiss:NO];
        self.actionMenu = nil;
    }
    
    if (dateFormatter) {
        dateFormatter = nil;
    }
    
    initialAttributedStringForOutgoingMessage = nil;
    initialAttributedStringForIncomingMessage = nil;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    if (isBackPaginationInProgress || isJoinRequestInProgress) {
        // Busy - be sure that activity indicator is running
        [_activityIndicator startAnimating];
    }
    
    if (mostRecentEventIdOnViewWillDisappear) {
        if (messages) {
            MXEvent *mxEvent = [messages lastObject];
            if ([mxEvent.eventId isEqualToString:mostRecentEventIdOnViewWillDisappear] == NO) {
                // Some new events have been received for this room, scroll to bottom to focus on them
                forceScrollToBottomOnViewDidAppear = YES;
            }
        }
        mostRecentEventIdOnViewWillDisappear = nil;
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onTextFieldChange:) name:UITextFieldTextDidChangeNotification object:nil];
    
    // Set visible room id
    [AppDelegate theDelegate].masterTabBarController.visibleRoomId = self.roomId;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    // hide action
    if (self.actionMenu) {
        [self.actionMenu dismiss:NO];
        self.actionMenu = nil;
    }
    
    // Hide members by default
    [self hideRoomMembers];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UITextFieldTextDidChangeNotification object:nil];
    
    // We store the eventID of the last known event (if any) in order to scroll to bottom when view will appear, if new events have been received
    if (messages) {
        MXEvent *mxEvent = [messages lastObject];
        mostRecentEventIdOnViewWillDisappear = mxEvent.eventId;
    }
    
    // Reset visible room id
    [AppDelegate theDelegate].masterTabBarController.visibleRoomId = nil;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    if (forceScrollToBottomOnViewDidAppear) {
        // Scroll to the bottom
        [self scrollToBottomAnimated:animated];
        forceScrollToBottomOnViewDidAppear = NO;
    }
}

#pragma mark - room ID

- (void)setRoomId:(NSString *)roomId {
    if ([self.roomId isEqualToString:roomId] == NO) {
        _roomId = roomId;
        // Reload room data here
        [self configureView];
    }
}

#pragma mark - UIGestureRecognizer delegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.view == self.membersView) {
        // Compute actual frame of the displayed members list
        CGRect frame = self.membersTableView.frame;
        if (self.membersTableView.tableFooterView.frame.origin.y < frame.size.height) {
            frame.size.height = self.membersTableView.tableFooterView.frame.origin.y;
        }
        // gestureRecognizer should begin only if tap is outside members list
        return !CGRectContainsPoint(frame, [gestureRecognizer locationInView:self.membersView]);
    }
    return YES;
}

#pragma mark - Internal methods

- (void)configureView {
    // Check whether a request is in progress to join the room
    if (isJoinRequestInProgress) {
        // Busy - be sure that activity indicator is running
        [_activityIndicator startAnimating];
        return;
    }
    
    // Remove potential listener
    if (messagesListener && mxRoom) {
        [mxRoom removeListener:messagesListener];
        messagesListener = nil;
    }
    // The whole room history is flushed here to rebuild it from the current instant (live)
    messages = nil;
    // Disable room title edition
    self.roomNameTextField.enabled = NO;
    
    // Update room data
    if (self.roomId) {
        MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
        mxRoom = [mxHandler.mxSession room:self.roomId];
        
        // Update room title
        self.roomNameTextField.text = mxRoom.state.displayname;
        
        // Check first whether we have to join the room
        if (mxRoom.state.membership == MXMembershipInvite) {
            isJoinRequestInProgress = YES;
            [_activityIndicator startAnimating];
            [mxRoom join:^{
                [_activityIndicator stopAnimating];
                isJoinRequestInProgress = NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self configureView];
                });
            } failure:^(NSError *error) {
                [_activityIndicator stopAnimating];
                isJoinRequestInProgress = NO;
                NSLog(@"Failed to join room (%@): %@", mxRoom.state.displayname, error);
                //Alert user
                [[AppDelegate theDelegate] showErrorAsAlert:error];
            }];
            return;
        }
        
        // Enable room title edition
        self.roomNameTextField.enabled = YES;
        
        messages = [NSMutableArray array];
        // Register a listener to handle messages
        messagesListener = [mxRoom listenToEventsOfTypes:mxHandler.mxSession.eventsFilterForMessages onEvent:^(MXEvent *event, MXEventDirection direction, MXRoomState *roomState) {
            BOOL shouldScrollToBottom = NO;
            
            // Handle first live events
            if (direction == MXEventDirectionForwards) {
                // For outgoing message, remove the temporary event
                if ([event.userId isEqualToString:[MatrixHandler sharedHandler].userId]) {
                    NSUInteger index = messages.count;
                    while (index--) {
                        MXEvent *mxEvent = [messages objectAtIndex:index];
                        if ([mxEvent.eventId isEqualToString:event.eventId]) {
                            [messages replaceObjectAtIndex:index withObject:event];
                            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
                            [self.messagesTableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
                            return;
                        }
                    }
                }
                // Here a new event is added
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:messages.count inSection:0];
                [messages addObject:event];
                shouldScrollToBottom = (self.messagesTableView.contentOffset.y + self.messagesTableView.frame.size.height >= self.messagesTableView.contentSize.height);
                
                // Refresh table display (Disable animation during cells insertion to prevent flickering)
                [UIView setAnimationsEnabled:NO];
                [self.messagesTableView beginUpdates];
                if (indexPath.row > 0) {
                    NSIndexPath *prevIndexPath = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:0];
                    [self.messagesTableView reloadRowsAtIndexPaths:@[prevIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                }
                [self.messagesTableView insertRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
                [self.messagesTableView endUpdates];
                [UIView setAnimationsEnabled:YES];
            } else if (isBackPaginationInProgress && direction == MXEventDirectionBackwards) {
                // Back pagination is in progress, we add an old event at the beginning of messages
                [messages insertObject:event atIndex:0];
                backPaginationAddedItemsNb++;
                // Display is refreshed at the end of back pagination (see onComplete block)
            }
            
            if (shouldScrollToBottom) {
                [self scrollToBottomAnimated:YES];
            }
        }];
        
        // Trigger a back pagination by reseting first backState to get room history from live
        [mxRoom resetBackState];
        [self triggerBackPagination];
    } else {
        mxRoom = nil;
        // Update room title
        self.roomNameTextField.text = nil;
    }
    
    [self.messagesTableView reloadData];
}

- (void)scrollToBottomAnimated:(BOOL)animated {
    // Scroll table view to the bottom
    NSInteger rowNb = messages.count;
    if (rowNb) {
        [self.messagesTableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:(rowNb - 1) inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:animated];
    }
}

- (void)triggerBackPagination {
    // Check whether a back pagination is already in progress
    if (isBackPaginationInProgress) {
        return;
    }
    
    if (mxRoom.canPaginate) {
        [_activityIndicator startAnimating];
        isBackPaginationInProgress = YES;
        backPaginationAddedItemsNb = 0;
        
        [mxRoom paginateBackMessages:20 complete:^{
            if (backPaginationAddedItemsNb) {
                // Prepare insertion of new rows at the top of the table (compute cumulative height of added cells)
                NSMutableArray *indexPaths = [NSMutableArray arrayWithCapacity:backPaginationAddedItemsNb];
                NSIndexPath *indexPath;
                CGFloat verticalOffset = 0;
                for (NSUInteger index = 0; index < backPaginationAddedItemsNb; index++) {
                    indexPath = [NSIndexPath indexPathForRow:index inSection:0];
                    [indexPaths addObject:indexPath];
                    verticalOffset += [self tableView:self.messagesTableView heightForRowAtIndexPath:indexPath];
                }
                
                // Disable animation during cells insertion to prevent flickering
                [UIView setAnimationsEnabled:NO];
                // Store the current content offset
                CGPoint contentOffset = self.messagesTableView.contentOffset;
                [self.messagesTableView beginUpdates];
                [self.messagesTableView insertRowsAtIndexPaths:indexPaths withRowAnimation:UITableViewRowAnimationNone];
                [self.messagesTableView endUpdates];
                // Enable animation again
                [UIView setAnimationsEnabled:YES];
                // Fix vertical offset in order to prevent scrolling down
                contentOffset.y += verticalOffset;
                [self.messagesTableView setContentOffset:contentOffset animated:NO];
                [_activityIndicator stopAnimating];
                isBackPaginationInProgress = NO;
                
                // Move the current message at the middle of the visible area (dispatch this action in order to let table end its refresh)
                indexPath = [NSIndexPath indexPathForRow:(backPaginationAddedItemsNb - 1) inSection:0];
                backPaginationAddedItemsNb = 0;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.messagesTableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
                });
            } else {
                // Here there was no event related to the `messages` property
                [_activityIndicator stopAnimating];
                isBackPaginationInProgress = NO;
                // Trigger a new back pagination (if possible)
                [self triggerBackPagination];
            }
        } failure:^(NSError *error) {
            [_activityIndicator stopAnimating];
            isBackPaginationInProgress = NO;
            backPaginationAddedItemsNb = 0;
            NSLog(@"Failed to paginate back: %@", error);
            //Alert user
            [[AppDelegate theDelegate] showErrorAsAlert:error];
        }];
    }
}

# pragma mark - Room members

- (void)showHideRoomMembers:(id)sender {
    // Check whether the members list is displayed
    if (members) {
        [self hideRoomMembers];
    } else {
        [self hideAttachmentView];
        [self showRoomMembers];
    }
}

- (void)updateRoomMembers {
     members = [[mxRoom.state members] sortedArrayUsingComparator:^NSComparisonResult(MXRoomMember *member1, MXRoomMember *member2) {
         // Move banned and left members at the end of the list
         if (member1.membership == MXMembershipLeave || member1.membership == MXMembershipBan) {
             if (member2.membership != MXMembershipLeave && member2.membership != MXMembershipBan) {
                 return NSOrderedDescending;
             }
         } else if (member2.membership == MXMembershipLeave || member2.membership == MXMembershipBan) {
             return NSOrderedAscending;
         }
         
         // Move invited members just before left and banned members
         if (member1.membership == MXMembershipInvite) {
             if (member2.membership != MXMembershipInvite) {
                 return NSOrderedDescending;
             }
         } else if (member2.membership == MXMembershipInvite) {
             return NSOrderedAscending;
         }
         
         if ([[AppSettings sharedSettings] sortMembersUsingLastSeenTime]) {
             // Get the users that correspond to these members
             MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
             MXUser *user1 = [mxHandler.mxSession user:member1.userId];
             MXUser *user2 = [mxHandler.mxSession user:member2.userId];
             
             // Move users who are not online or unavailable at the end (before invited users)
             if ((user1.presence == MXPresenceOnline) || (user1.presence == MXPresenceUnavailable)) {
                 if ((user2.presence != MXPresenceOnline) && (user2.presence != MXPresenceUnavailable)) {
                     return NSOrderedAscending;
                 }
             } else if ((user2.presence == MXPresenceOnline) || (user2.presence == MXPresenceUnavailable)) {
                 return NSOrderedDescending;
             } else {
                 // Here both users are neither online nor unavailable (the lastActive ago is useless)
                 // We will sort them according to their display, by keeping in front the offline users
                 if (user1.presence == MXPresenceOffline) {
                     if (user2.presence != MXPresenceOffline) {
                         return NSOrderedAscending;
                     }
                 } else if (user2.presence == MXPresenceOffline) {
                     return NSOrderedDescending;
                 }
                 return [[mxRoom.state memberName:member1.userId] compare:[mxRoom.state memberName:member2.userId] options:NSCaseInsensitiveSearch];
             }
             
             // Consider user's lastActive ago value
             if (user1.lastActiveAgo < user2.lastActiveAgo) {
                 return NSOrderedAscending;
             } else if (user1.lastActiveAgo == user2.lastActiveAgo) {
                 return [[mxRoom.state memberName:member1.userId] compare:[mxRoom.state memberName:member2.userId] options:NSCaseInsensitiveSearch];
             }
             return NSOrderedDescending;
         } else {
             // Move user without display name at the end (before invited users)
             if (member1.displayname.length) {
                 if (!member2.displayname.length) {
                     return NSOrderedAscending;
                 }
             } else if (member2.displayname.length) {
                 return NSOrderedDescending;
             }
             
             return [[mxRoom.state memberName:member1.userId] compare:[mxRoom.state memberName:member2.userId] options:NSCaseInsensitiveSearch];
         }
     }];
}

- (void)showRoomMembers {
    // Dismiss keyboard
    [self dismissKeyboard];
    
    [self updateRoomMembers];
    // Register a listener for events that concern room members
    MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
    NSArray *mxMembersEvents = @[
                                 kMXEventTypeStringRoomMember,
                                 kMXEventTypeStringRoomPowerLevels,
                                 kMXEventTypeStringPresence
                                 ];
    membersListener = [mxHandler.mxSession listenToEventsOfTypes:mxMembersEvents onEvent:^(MXEvent *event, MXEventDirection direction, id customObject) {
        // consider only live event
        if (direction == MXEventDirectionForwards) {
            // Check the room Id (if any)
            if (event.roomId && [event.roomId isEqualToString:self.roomId] == NO) {
                // This event does not concern the current room members
                return;
            }
            
            // Hide potential action sheet
            if (self.actionMenu) {
                [self.actionMenu dismiss:NO];
                self.actionMenu = nil;
            }
            // Refresh members list
            [self updateRoomMembers];
            [self.membersTableView reloadData];
        }
    }];
    
    self.membersView.hidden = NO;
    [self.membersTableView reloadData];
}

- (void)hideRoomMembers {
    if (membersListener) {
        MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
        [mxHandler.mxSession removeListener:membersListener];
        membersListener = nil;
    }
    self.membersView.hidden = YES;
    members = nil;
}

# pragma mark - Attachment handling

- (void)showAttachmentView:(UIGestureRecognizer *)gestureRecognizer {
    CustomImageView *attachment = (CustomImageView*)gestureRecognizer.view;
    [self dismissKeyboard];
    
    // Retrieve attachment information
    NSDictionary *content = attachment.mediaInfo;
    NSString *msgtype = content[@"msgtype"];
    if ([msgtype isEqualToString:kMXMessageTypeImage]) {
        NSString *url =content[@"url"];
        if (url.length) {
            highResImage = [[CustomImageView alloc] initWithFrame:self.membersView.frame];
            highResImage.contentMode = UIViewContentModeScaleAspectFit;
            highResImage.backgroundColor = [UIColor blackColor];
            highResImage.imageURL = url;
            [self.view addSubview:highResImage];
            
            // Add tap recognizer to hide attachment
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideAttachmentView)];
            [tap setNumberOfTouchesRequired:1];
            [tap setNumberOfTapsRequired:1];
            [highResImage addGestureRecognizer:tap];
            highResImage.userInteractionEnabled = YES;
        }
    } else if ([msgtype isEqualToString:kMXMessageTypeVideo]) {
        NSString *url =content[@"url"];
        if (url.length) {
            NSString *mimetype = nil;
            if (content[@"info"]) {
                mimetype = content[@"info"][@"mimetype"];
            }
            AVAudioSessionCategory = [[AVAudioSession sharedInstance] category];
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
            videoPlayer = [[MPMoviePlayerController alloc] init];
            if (videoPlayer != nil) {
                videoPlayer.scalingMode = MPMovieScalingModeAspectFit;
                [self.view addSubview:videoPlayer.view];
                [videoPlayer setFullscreen:YES animated:NO];
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                         selector:@selector(moviePlayerPlaybackDidFinishNotification:)
                                                             name:MPMoviePlayerPlaybackDidFinishNotification
                                                           object:nil];
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                         selector:@selector(moviePlayerWillExitFullscreen:)
                                                             name:MPMoviePlayerWillExitFullscreenNotification
                                                           object:videoPlayer];
                [MediaManager prepareMedia:url mimeType:mimetype success:^(NSString *cacheFilePath) {
                    if (cacheFilePath) {
                        if (tmpCachedAttachments == nil) {
                            tmpCachedAttachments = [NSMutableArray array];
                        }
                        if ([tmpCachedAttachments indexOfObject:cacheFilePath]) {
                            [tmpCachedAttachments addObject:cacheFilePath];
                        }
                    }
                    videoPlayer.contentURL = [NSURL fileURLWithPath:cacheFilePath];
                    [videoPlayer play];
                } failure:^(NSError *error) {
                    [self hideAttachmentView];
                    //Alert user
                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            }
        }
    } else if ([msgtype isEqualToString:kMXMessageTypeAudio]) {
    } else if ([msgtype isEqualToString:kMXMessageTypeLocation]) {
    }
}

- (void)hideAttachmentView {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MPMoviePlayerPlaybackDidFinishNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MPMoviePlayerWillExitFullscreenNotification object:nil];
    
    if (highResImage) {
        [highResImage removeFromSuperview];
        highResImage = nil;
    }
    // Restore audio category
    if (AVAudioSessionCategory) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategory error:nil];
    }
    if (videoPlayer) {
        [videoPlayer stop];
        [videoPlayer setFullscreen:NO];
        [videoPlayer.view removeFromSuperview];
        videoPlayer = nil;
    }
}

- (void)moviePlayerWillExitFullscreen:(NSNotification*)notification {
    if (notification.object == videoPlayer) {
        [self hideAttachmentView];
    }
}

- (void)moviePlayerPlaybackDidFinishNotification:(NSNotification *)notification {
    NSDictionary *notificationUserInfo = [notification userInfo];
    NSNumber *resultValue = [notificationUserInfo objectForKey:MPMoviePlayerPlaybackDidFinishReasonUserInfoKey];
    MPMovieFinishReason reason = [resultValue intValue];
    
    // error cases
    if (reason == MPMovieFinishReasonPlaybackError) {
        NSError *mediaPlayerError = [notificationUserInfo objectForKey:@"error"];
        if (mediaPlayerError) {
            NSLog(@"Playback failed with error description: %@", [mediaPlayerError localizedDescription]);
            [self hideAttachmentView];
            //Alert user
            [[AppDelegate theDelegate] showErrorAsAlert:mediaPlayerError];
        }
    }
}

#pragma mark - Keyboard handling

- (void)onKeyboardWillShow:(NSNotification *)notif {
    NSValue *rectVal = notif.userInfo[UIKeyboardFrameEndUserInfoKey];
    CGRect endRect = rectVal.CGRectValue;
    
    UIEdgeInsets insets = self.messagesTableView.contentInset;
    // Handle portrait/landscape mode
    insets.bottom = (endRect.origin.y == 0) ? endRect.size.width : endRect.size.height;
    self.messagesTableView.contentInset = insets;
    
    [self scrollToBottomAnimated:YES];
    
    // Move up control view
    // Don't forget the offset related to tabBar
    _controlViewBottomConstraint.constant = insets.bottom - [AppDelegate theDelegate].masterTabBarController.tabBar.frame.size.height;
}

- (void)onKeyboardWillHide:(NSNotification *)notif {
    UIEdgeInsets insets = self.messagesTableView.contentInset;
    insets.bottom = self.controlView.frame.size.height;
    self.messagesTableView.contentInset = insets;
    
    _controlViewBottomConstraint.constant = 0;
}

- (void)dismissKeyboard {
    // Hide the keyboard
    [_messageTextField resignFirstResponder];
    [_roomNameTextField resignFirstResponder];
}

#pragma mark - UITableView data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // Check table view members vs messages
    if (tableView == self.membersTableView)
    {
        return members.count;
    }
    
    return messages.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Check table view members vs messages
    if (tableView == self.membersTableView)
    {
        return 50;
    }
    
    // Compute here height of message cells
    CGFloat rowHeight;
    // Get event related to this row
    MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
    MXEvent *mxEvent = [messages objectAtIndex:indexPath.row];
    
    // Check whether the cell will display an attachment or a text message
    CGSize contentSize;
    NSString *displayText = nil;
    if ([mxHandler isAttachment:mxEvent]) {
        contentSize = [self attachmentContentSize:mxEvent];
        if (!contentSize.width || !contentSize.height) {
            // Check whether unsupported/unexpected messages should be exposed
            if ([AppSettings sharedSettings].hideUnsupportedMessages) {
                displayText = @"";
            } else {
                displayText = [NSString stringWithFormat:@"%@%@", kMatrixHandlerUnsupportedMessagePrefix, mxEvent.description];
            }
        }
    } else {
        displayText = [mxHandler displayTextFor:mxEvent inSubtitleMode:NO];
    }
    if (displayText) {
        contentSize = [self textContentSize:displayText];
    }
    
    // Check whether the previous message has been sent by the same user.
    // We group together messages from the same user. The user's picture and name are displayed only for the first message.
    // We consider a new chunk when the user is different from the previous message's one.
    BOOL isNewChunk = YES;
    if (indexPath.row) {
        MXEvent *previousMxEvent = [messages objectAtIndex:indexPath.row - 1];
        if ([previousMxEvent.userId isEqualToString:mxEvent.userId]) {
            isNewChunk = NO;
        }
    }
    
    // Adjust cell height inside chunk
    rowHeight = contentSize.height;
    if (isNewChunk) {
        // The cell is the first cell of the chunk
        rowHeight += ROOM_MESSAGE_CELL_TEXTVIEW_TOP_CONST_DEFAULT;
    } else {
        // Inside chunk the height of the cell is reduced in order to reduce padding between messages
        rowHeight += ROOM_MESSAGE_CELL_TEXTVIEW_TOP_CONST_IN_CHUNK;
    }
    
    // Check whether the message is the last message of the current chunk
    BOOL isChunkEnd = YES;
    if (indexPath.row < messages.count - 1) {
        MXEvent *nextMxEvent = [messages objectAtIndex:indexPath.row + 1];
        if ([nextMxEvent.userId isEqualToString:mxEvent.userId]) {
            isChunkEnd = NO;
        }
    }
    
    if (!isNewChunk && !isChunkEnd) {
        // Reduce again cell height to reduce space with the next cell
        rowHeight += ROOM_MESSAGE_CELL_TEXTVIEW_BOTTOM_CONST_GROUPED_CELL;
    } else {
        // The cell is the first cell of the chunk or the last one
        rowHeight += ROOM_MESSAGE_CELL_TEXTVIEW_BOTTOM_CONST_DEFAULT;
    }
    
    if (isNewChunk && isChunkEnd) {
        // When the chunk is composed by only one message, we consider the minimun cell height (50) in order to display correctly user's picture
        if (rowHeight < 50) {
            rowHeight = 50;
        }
    }
    
    return rowHeight;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
    
    // Check table view members vs messages
    if (tableView == self.membersTableView) {
        RoomMemberTableCell *memberCell = [tableView dequeueReusableCellWithIdentifier:@"RoomMemberCell" forIndexPath:indexPath];
        if (indexPath.row < members.count) {
            [memberCell setRoomMember:[members objectAtIndex:indexPath.row] withRoom:mxRoom];
        }
        
        return memberCell;
    }
    
    // Handle here room message cells
    RoomMessageTableCell *cell;
    MXEvent *mxEvent = [messages objectAtIndex:indexPath.row];
    BOOL isIncomingMsg = NO;
    BOOL enableLinkDetection = YES;
    
    if ([mxEvent.userId isEqualToString:mxHandler.userId]) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"OutgoingMessageCell" forIndexPath:indexPath];
        [((OutgoingMessageTableCell*)cell).activityIndicator stopAnimating];
        // Restore initial settings of text view
        if (initialAttributedStringForOutgoingMessage == nil) {
            initialAttributedStringForOutgoingMessage = cell.messageTextView.attributedText;
        } else {
            cell.messageTextView.attributedText = initialAttributedStringForOutgoingMessage;
            cell.messageTextView.dataDetectorTypes = UIDataDetectorTypeNone;
        }
    } else {
        cell = [tableView dequeueReusableCellWithIdentifier:@"IncomingMessageCell" forIndexPath:indexPath];
        isIncomingMsg = YES;
        // Restore initial settings of text view
        if (initialAttributedStringForIncomingMessage == nil) {
            initialAttributedStringForIncomingMessage = cell.messageTextView.attributedText;
        } else {
            cell.messageTextView.attributedText = initialAttributedStringForIncomingMessage;
            cell.messageTextView.dataDetectorTypes = UIDataDetectorTypeNone;
        }
    }
    
    // Restore initial settings of attachment ImageView
    cell.attachmentView.imageURL = nil; // Cancel potential attachment loading
    cell.attachmentView.hidden = YES;
    cell.playIconView.hidden = YES;
    // Remove all gesture recognizer
    while (cell.attachmentView.gestureRecognizers.count) {
        [cell.attachmentView removeGestureRecognizer:cell.attachmentView.gestureRecognizers[0]];
    }
    cell.attachmentViewTopAlignmentConstraint.constant = 0;
    cell.attachmentViewBottomAlignmentConstraint.constant = 0;
    
    // Check whether the previous message has been sent by the same user.
    // We group together messages from the same user. The user's picture and name are displayed only for the first message.
    // We consider a new chunk when the user is different from the previous message's one.
    BOOL isNewChunk = YES;
    if (indexPath.row) {
        MXEvent *previousMxEvent = [messages objectAtIndex:indexPath.row - 1];
        if ([previousMxEvent.userId isEqualToString:mxEvent.userId]) {
            isNewChunk = NO;
        }
    }
    
    if (isNewChunk) {
        // Adjust display of the first message of a chunk
        cell.pictureView.hidden = NO;
        cell.msgTextViewTopConstraint.constant = ROOM_MESSAGE_CELL_TEXTVIEW_TOP_CONST_DEFAULT;
        cell.msgTextViewBottomConstraint.constant = ROOM_MESSAGE_CELL_TEXTVIEW_BOTTOM_CONST_DEFAULT;
        cell.messageTextView.contentInset = UIEdgeInsetsZero;
        
        // Set user's picture
        cell.pictureView.placeholder = @"default-profile";
        cell.pictureView.imageURL = [mxRoom.state memberWithUserId:mxEvent.userId].avatarUrl;
        [cell.pictureView.layer setCornerRadius:cell.pictureView.frame.size.width / 2];
        cell.pictureView.clipsToBounds = YES;
    } else {
        // Adjust display of other messages of the chunk
        cell.pictureView.hidden = YES;
        // The height of this cell has been reduced in order to reduce padding between messages of the same chunk
        // We define here a negative constant for the top space between textView and its superview to display correctly the message text.
        cell.msgTextViewTopConstraint.constant = ROOM_MESSAGE_CELL_TEXTVIEW_TOP_CONST_IN_CHUNK;
        // Shift to the top the displayed message to reduce space with the previous messages
        UIEdgeInsets edgeInsets = UIEdgeInsetsZero;
        edgeInsets.top = ROOM_MESSAGE_CELL_TEXTVIEW_EDGE_INSET_TOP_IN_CHUNK;
        cell.messageTextView.contentInset = edgeInsets;
        
        // Check whether the next message belongs to the same chunk in order to define bottom space between textView and its superview
        cell.msgTextViewBottomConstraint.constant = ROOM_MESSAGE_CELL_TEXTVIEW_BOTTOM_CONST_DEFAULT;
        if (indexPath.row < messages.count - 1) {
            MXEvent *nextMxEvent = [messages objectAtIndex:indexPath.row + 1];
            if ([nextMxEvent.userId isEqualToString:mxEvent.userId]) {
                cell.msgTextViewBottomConstraint.constant = ROOM_MESSAGE_CELL_TEXTVIEW_BOTTOM_CONST_GROUPED_CELL;
            }
        }
    }
    
    // Update incoming/outgoing message layout
    if (isIncomingMsg) {
        IncomingMessageTableCell* incomingMsgCell = (IncomingMessageTableCell*)cell;
        // Display user's display name for the first meesage of a chunk, except if the name appears in the displayed text (see emote and membership event)
        if (isNewChunk && [mxHandler isNotification:mxEvent] == NO) {
            incomingMsgCell.userNameLabel.hidden = NO;
            incomingMsgCell.userNameLabel.text = [mxRoom.state memberName:mxEvent.userId];
        } else {
            incomingMsgCell.userNameLabel.hidden = YES;
        }
        
        // Reset text color
        cell.messageTextView.textColor = [UIColor blackColor];
    } else {
        OutgoingMessageTableCell* outgoingMsgCell = (OutgoingMessageTableCell*)cell;
        // Hide unsent label by default
        outgoingMsgCell.unsentLabel.hidden = YES;
        
        // Set the right text color for outgoing messages
        if ([mxEvent.eventId hasPrefix:kLocalEchoEventIdPrefix]) {
            cell.messageTextView.textColor = [UIColor lightGrayColor];
            enableLinkDetection = NO;
        } else if ([mxEvent.eventId hasPrefix:kFailedEventId]) {
            cell.messageTextView.textColor = [UIColor redColor];
            enableLinkDetection = NO;
            outgoingMsgCell.unsentLabel.hidden = NO;
            // Align unsent label with the textView
            outgoingMsgCell.unsentLabelTopConstraint.constant = cell.msgTextViewTopConstraint.constant + cell.messageTextView.contentInset.top - ROOM_MESSAGE_CELL_TEXTVIEW_EDGE_INSET_TOP_IN_CHUNK;
        } else {
            cell.messageTextView.textColor = [UIColor blackColor];
        }
    }
    
    if ([mxHandler isAttachment:mxEvent]) {
        cell.messageTextView.text = nil; // Note: Text view is used as attachment background view
        CGSize contentSize = [self attachmentContentSize:mxEvent];
        if (!contentSize.width || !contentSize.height) {
            NSLog(@"ERROR: Unsupported message %@", mxEvent.description);
            // Check whether unsupported/unexpected messages should be exposed
            if ([AppSettings sharedSettings].hideUnsupportedMessages == NO) {
                // Display event content as unsupported message
                cell.messageTextView.text = [NSString stringWithFormat:@"%@%@", kMatrixHandlerUnsupportedMessagePrefix, mxEvent.description];
                cell.messageTextView.textColor = [UIColor redColor];
                enableLinkDetection = NO;
            }
            // Adjust constraint constant
            cell.msgTextViewWidthConstraint.constant = ROOM_MESSAGE_CELL_MAX_TEXTVIEW_WIDTH;
        } else {
            cell.attachmentView.hidden = NO;
            // Fade attachments during upload
            if (isIncomingMsg == NO && [mxEvent.eventId hasPrefix:kLocalEchoEventIdPrefix]) {
                cell.attachmentView.alpha = 0.5;
                [((OutgoingMessageTableCell*)cell).activityIndicator startAnimating];
            } else {
                cell.attachmentView.alpha = 1;
            }
            
            NSString *msgtype = mxEvent.content[@"msgtype"];
            if ([msgtype isEqualToString:kMXMessageTypeImage] || [msgtype isEqualToString:kMXMessageTypeVideo]) {
                NSString *url = nil;
                if ([msgtype isEqualToString:kMXMessageTypeVideo]) {
                    cell.playIconView.hidden = NO;
                    if (mxEvent.content[@"info"]) {
                        url = mxEvent.content[@"info"][@"thumbnail_url"];
                    }
                } else {
                    url = mxEvent.content[@"thumbnail_url"];
                }
                
                if (url == nil) {
                    url = mxEvent.content[@"url"];
                }
                cell.attachmentView.imageURL = url;
                
                // Add tap recognizer to open attachment
                UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showAttachmentView:)];
                [tap setNumberOfTouchesRequired:1];
                [tap setNumberOfTapsRequired:1];
                [tap setDelegate:self];
                [cell.attachmentView addGestureRecognizer:tap];
                // Store attachment content description used in showAttachmentView:
                cell.attachmentView.mediaInfo = mxEvent.content;
            } else {
                cell.attachmentView.imageURL = nil;
            }
            
            // Adjust constraint constant
            cell.msgTextViewWidthConstraint.constant = contentSize.width;
            // Align attachment inside text view by considering text view edge inset
            cell.attachmentViewTopAlignmentConstraint.constant = ROOM_MESSAGE_CELL_IMAGE_MARGIN + cell.messageTextView.contentInset.top;
            cell.attachmentViewBottomAlignmentConstraint.constant = -ROOM_MESSAGE_CELL_IMAGE_MARGIN + cell.messageTextView.contentInset.top;
        }
    } else {
        NSString *displayText = [mxHandler displayTextFor:mxEvent inSubtitleMode:NO];
        // Update text color according to text content
        if ([displayText hasPrefix:kMatrixHandlerUnsupportedMessagePrefix]) {
            cell.messageTextView.textColor = [UIColor redColor];
            enableLinkDetection = NO;
        } else if (isIncomingMsg && ([displayText rangeOfString:mxHandler.userDisplayName options:NSCaseInsensitiveSearch].location != NSNotFound || [displayText rangeOfString:mxHandler.userId options:NSCaseInsensitiveSearch].location != NSNotFound)) {
            cell.messageTextView.textColor = [UIColor blueColor];
        }
        cell.messageTextView.text = displayText;
        // Adjust textView width constraint
        cell.msgTextViewWidthConstraint.constant = [self textContentSize:displayText].width;
    }
    
    // Turn on link detection only when it is usefull
    if (enableLinkDetection) {
        cell.messageTextView.dataDetectorTypes = UIDataDetectorTypeLink;
    }
    
    // Handle timestamp display
    if (dateFormatter && mxEvent.originServerTs) {
        cell.dateTimeLabel.hidden = NO;
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:mxEvent.originServerTs/1000];
        cell.dateTimeLabel.text = [dateFormatter stringFromDate:date];
        // Align dateTime label with the textView
        cell.dateTimeLabelTopConstraint.constant = cell.msgTextViewTopConstraint.constant + cell.messageTextView.contentInset.top - ROOM_MESSAGE_CELL_TEXTVIEW_EDGE_INSET_TOP_IN_CHUNK;
    } else {
        cell.dateTimeLabel.hidden = YES;
    }
    
    return cell;
}

- (CGSize)textContentSize:(NSString*)textMsg {
    // Use a TextView template to compute cell height
    UITextView *dummyTextView = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, ROOM_MESSAGE_CELL_MAX_TEXTVIEW_WIDTH, MAXFLOAT)];
    dummyTextView.font = [UIFont systemFontOfSize:14];
    dummyTextView.text = textMsg;
    return [dummyTextView sizeThatFits:dummyTextView.frame.size];
}

- (CGSize)attachmentContentSize:(MXEvent*)mxEvent {
    CGSize contentSize;
    NSString *msgtype = mxEvent.content[@"msgtype"];
    if ([msgtype isEqualToString:kMXMessageTypeImage] || [msgtype isEqualToString:kMXMessageTypeVideo]) {
        CGFloat width, height;
        width = height = 0;
        
        NSDictionary *thumbInfo = nil;
        if ([msgtype isEqualToString:kMXMessageTypeVideo]) {
            if (mxEvent.content[@"info"]) {
                thumbInfo = mxEvent.content[@"info"][@"thumbnail_info"];
            }
        } else {
            thumbInfo = mxEvent.content[@"thumbnail_info"];
        }
        
        if (thumbInfo) {
            width = [thumbInfo[@"w"] integerValue] + 2 * ROOM_MESSAGE_CELL_IMAGE_MARGIN;
            height = [thumbInfo[@"h"] integerValue] + 2 * ROOM_MESSAGE_CELL_IMAGE_MARGIN;
            if (width > ROOM_MESSAGE_CELL_MAX_TEXTVIEW_WIDTH || height > ROOM_MESSAGE_CELL_MAX_TEXTVIEW_WIDTH) {
                if (width > height) {
                    height = (height * ROOM_MESSAGE_CELL_MAX_TEXTVIEW_WIDTH) / width;
                    height = floorf(height / 2) * 2;
                    width = ROOM_MESSAGE_CELL_MAX_TEXTVIEW_WIDTH;
                } else {
                    width = (width * ROOM_MESSAGE_CELL_MAX_TEXTVIEW_WIDTH) / height;
                    width = floorf(width / 2) * 2;
                    height = ROOM_MESSAGE_CELL_MAX_TEXTVIEW_WIDTH;
                }
            }
        }
        contentSize = CGSizeMake(width, height);
    } else {
        contentSize = CGSizeMake(40, 40);
    }
    return contentSize;
}

#pragma mark - UITableView delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    // Check table view members vs messages
    if (tableView == self.membersTableView) {
        // List action(s) available on this member
        // TODO: Check user's power level before allowing an action (kick, ban, ...)
        MXRoomMember *roomMember = [members objectAtIndex:indexPath.row];
        MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
        __weak typeof(self) weakSelf = self;
        if (self.actionMenu) {
            [self.actionMenu dismiss:NO];
            self.actionMenu = nil;
        }
        
        // Consider the case of the user himself
        if ([roomMember.userId isEqualToString:mxHandler.userId]) {
            self.actionMenu = [[CustomAlert alloc] initWithTitle:@"Select an action:" message:nil style:CustomAlertStyleActionSheet];
            [self.actionMenu addActionWithTitle:@"Leave" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                if (weakSelf) {
                    weakSelf.actionMenu = nil;
                    MXRoom *currentRoom = [[MatrixHandler sharedHandler].mxSession room:weakSelf.roomId];
                    [currentRoom leave:^{
                        // Back to recents
                        [weakSelf.navigationController popViewControllerAnimated:YES];
                    } failure:^(NSError *error) {
                        NSLog(@"Leave room %@ failed: %@", weakSelf.roomId, error);
                        //Alert user
                        [[AppDelegate theDelegate] showErrorAsAlert:error];
                    }];
                }
            }];
        } else {
            // Consider membership of the selected member
            switch (roomMember.membership) {
                case MXMembershipInvite:
                case MXMembershipJoin: {
                    self.actionMenu = [[CustomAlert alloc] initWithTitle:@"Select an action:" message:nil style:CustomAlertStyleActionSheet];
                    [self.actionMenu addActionWithTitle:@"Kick" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                        if (weakSelf) {
                            weakSelf.actionMenu = nil;
                            [[MatrixHandler sharedHandler].mxRestClient kickUser:roomMember.userId
                                                                        fromRoom:weakSelf.roomId
                                                                          reason:nil
                                                                         success:^{
                                                                         }
                                                                         failure:^(NSError *error) {
                                                                             NSLog(@"Kick %@ failed: %@", roomMember.userId, error);
                                                                             //Alert user
                                                                             [[AppDelegate theDelegate] showErrorAsAlert:error];
                                                                         }];
                        }
                    }];
                    [self.actionMenu addActionWithTitle:@"Ban" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                        if (weakSelf) {
                            weakSelf.actionMenu = nil;
                            [[MatrixHandler sharedHandler].mxRestClient banUser:roomMember.userId
                                                                         inRoom:weakSelf.roomId
                                                                         reason:nil
                                                                        success:^{
                                                                        }
                                                                        failure:^(NSError *error) {
                                                                            NSLog(@"Ban %@ failed: %@", roomMember.userId, error);
                                                                            //Alert user
                                                                            [[AppDelegate theDelegate] showErrorAsAlert:error];
                                                                        }];
                        }
                    }];
                    break;
                }
                case MXMembershipLeave: {
                    self.actionMenu = [[CustomAlert alloc] initWithTitle:@"Select an action:" message:nil style:CustomAlertStyleActionSheet];
                    [self.actionMenu addActionWithTitle:@"Invite" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                        if (weakSelf) {
                            weakSelf.actionMenu = nil;
                            [[MatrixHandler sharedHandler].mxRestClient inviteUser:roomMember.userId
                                                                            toRoom:weakSelf.roomId
                                                                           success:^{
                                                                           }
                                                                           failure:^(NSError *error) {
                                                                               NSLog(@"Invite %@ failed: %@", roomMember.userId, error);
                                                                               //Alert user
                                                                               [[AppDelegate theDelegate] showErrorAsAlert:error];
                                                                           }];
                        }
                    }];
                    [self.actionMenu addActionWithTitle:@"Ban" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                        if (weakSelf) {
                            weakSelf.actionMenu = nil;
                            [[MatrixHandler sharedHandler].mxRestClient banUser:roomMember.userId
                                                                         inRoom:weakSelf.roomId
                                                                         reason:nil
                                                                        success:^{
                                                                        }
                                                                        failure:^(NSError *error) {
                                                                            NSLog(@"Ban %@ failed: %@", roomMember.userId, error);
                                                                            //Alert user
                                                                            [[AppDelegate theDelegate] showErrorAsAlert:error];
                                                                        }];
                        }
                    }];
                    break;
                }
                case MXMembershipBan: {
                    self.actionMenu = [[CustomAlert alloc] initWithTitle:@"Select an action:" message:nil style:CustomAlertStyleActionSheet];
                    [self.actionMenu addActionWithTitle:@"Unban" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                        if (weakSelf) {
                            weakSelf.actionMenu = nil;
                            [[MatrixHandler sharedHandler].mxRestClient unbanUser:roomMember.userId
                                                                           inRoom:weakSelf.roomId
                                                                          success:^{
                                                                          }
                                                                          failure:^(NSError *error) {
                                                                              NSLog(@"Unban %@ failed: %@", roomMember.userId, error);
                                                                              //Alert user
                                                                              [[AppDelegate theDelegate] showErrorAsAlert:error];
                                                                          }];
                        }
                    }];
                    break;
                }
                default: {
                    break;
                }
            }
        }
        
        // Display the action sheet (if any)
        if (self.actionMenu) {
            self.actionMenu.cancelButtonIndex = [self.actionMenu addActionWithTitle:@"Cancel" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                weakSelf.actionMenu = nil;
            }];
            [self.actionMenu showInViewController:self];
        }
        
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    } else if (tableView == self.messagesTableView) {
        // Dismiss keyboard when user taps on messages table view content
        [self dismissKeyboard];
    }
}

// Detect vertical bounce at the top of the tableview to trigger pagination
- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    if (scrollView == self.messagesTableView) {
        // paginate ?
        if (scrollView.contentOffset.y < -64)
        {
            [self triggerBackPagination];
        }
    }
}

#pragma mark - UITextField delegate

- (void)onTextFieldChange:(NSNotification *)notif {
    NSString *msg = _messageTextField.text;
    
    if (msg.length) {
        _sendBtn.enabled = YES;
        _sendBtn.alpha = 1;
        // Reset potential placeholder (used in case of wrong command usage)
        _messageTextField.placeholder = nil;
    } else {
        _sendBtn.enabled = NO;
        _sendBtn.alpha = 0.5;
    }
}

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    if (textField == self.roomNameTextField) {
        self.roomNameTextField.borderStyle = UITextBorderStyleRoundedRect;
        self.roomNameTextField.backgroundColor = [UIColor whiteColor];
    }
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == self.roomNameTextField) {
        self.roomNameTextField.borderStyle = UITextBorderStyleNone;
        self.roomNameTextField.backgroundColor = [UIColor clearColor];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField*) textField {
    // "Done" key has been pressed
    [textField resignFirstResponder];
    
    if (textField == self.roomNameTextField) {
        NSString *roomName = self.roomNameTextField.text;
        if ([roomName isEqualToString:mxRoom.state.name] == NO) {
            [self.activityIndicator startAnimating];
            MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
            [mxHandler.mxRestClient setRoomName:self.roomId name:roomName success:^{
                if (isBackPaginationInProgress == NO) {
                    [self.activityIndicator stopAnimating];
                }
            } failure:^(NSError *error) {
                if (isBackPaginationInProgress == NO) {
                    [self.activityIndicator stopAnimating];
                }
                // Revert change
                self.roomNameTextField.text = mxRoom.state.displayname;
                NSLog(@"Rename room failed: %@", error);
                //Alert user
                [[AppDelegate theDelegate] showErrorAsAlert:error];
            }];
        }
    }
    return YES;
}

#pragma mark - Actions

- (IBAction)onButtonPressed:(id)sender {
    if (sender == _sendBtn) {
        NSString *msgTxt = self.messageTextField.text;
        
        // Handle potential commands in room chat
        if ([self isIRCStyleCommand:msgTxt] == NO) {
            [self postTextMessage:msgTxt];
        }
        
        self.messageTextField.text = nil;
        // disable send button
        [self onTextFieldChange:nil];
    } else if (sender == _optionBtn) {
        [self dismissKeyboard];
        
        // Display action menu: Add attachments, Invite user...
        __weak typeof(self) weakSelf = self;
        self.actionMenu = [[CustomAlert alloc] initWithTitle:@"Select an action:" message:nil style:CustomAlertStyleActionSheet];
        // Attachments
        [self.actionMenu addActionWithTitle:@"Attach" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
            if (weakSelf) {
                // Ask for attachment type
                weakSelf.actionMenu = [[CustomAlert alloc] initWithTitle:@"Select an attachment type:" message:nil style:CustomAlertStyleActionSheet];
                [weakSelf.actionMenu addActionWithTitle:@"Media" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                    if (weakSelf) {
                        weakSelf.actionMenu = nil;
                        // Open media gallery
                        UIImagePickerController *mediaPicker = [[UIImagePickerController alloc] init];
                        mediaPicker.delegate = weakSelf;
                        mediaPicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
                        mediaPicker.allowsEditing = NO;
                        mediaPicker.mediaTypes = [NSArray arrayWithObjects:(NSString *)kUTTypeImage, (NSString *)kUTTypeMovie, nil];
                        [[AppDelegate theDelegate].masterTabBarController presentMediaPicker:mediaPicker];
                    }
                }];
                weakSelf.actionMenu.cancelButtonIndex = [weakSelf.actionMenu addActionWithTitle:@"Cancel" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                    weakSelf.actionMenu = nil;
                }];
                [weakSelf.actionMenu showInViewController:weakSelf];
            }
        }];
        // Invitation
        [self.actionMenu addActionWithTitle:@"Invite" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
            if (weakSelf) {
                // Ask for userId to invite
                weakSelf.actionMenu = [[CustomAlert alloc] initWithTitle:@"User ID:" message:nil style:CustomAlertStyleAlert];
                weakSelf.actionMenu.cancelButtonIndex = [weakSelf.actionMenu addActionWithTitle:@"Cancel" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                    weakSelf.actionMenu = nil;
                }];
                [weakSelf.actionMenu addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                    textField.secureTextEntry = NO;
                    textField.placeholder = @"ex: @bob:homeserver";
                }];
                [weakSelf.actionMenu addActionWithTitle:@"Invite" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
                    UITextField *textField = [alert textFieldAtIndex:0];
                    NSString *userId = textField.text;
                    weakSelf.actionMenu = nil;
                    if (userId.length) {
                        [[MatrixHandler sharedHandler].mxRestClient inviteUser:userId toRoom:weakSelf.roomId success:^{
                            
                        } failure:^(NSError *error) {
                            NSLog(@"Invite %@ failed: %@", userId, error);
                            //Alert user
                            [[AppDelegate theDelegate] showErrorAsAlert:error];
                        }];
                    }
                }];
                [weakSelf.actionMenu showInViewController:weakSelf];
            }
        }];
        self.actionMenu.cancelButtonIndex = [self.actionMenu addActionWithTitle:@"Cancel" style:CustomAlertActionStyleDefault handler:^(CustomAlert *alert) {
             weakSelf.actionMenu = nil;
        }];
        weakSelf.actionMenu.sourceView = weakSelf.optionBtn;
        [self.actionMenu showInViewController:self];
    }
}

- (IBAction)showHideDateTime:(id)sender {
    if (dateFormatter) {
        // dateTime will be hidden
        dateFormatter = nil;
    } else {
        // dateTime will be visible
        NSString *dateFormat = @"MMM dd HH:mm";
        dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setLocale:[[NSLocale alloc] initWithLocaleIdentifier:[[[NSBundle mainBundle] preferredLocalizations] objectAtIndex:0]]];
        [dateFormatter setFormatterBehavior:NSDateFormatterBehavior10_4];
        [dateFormatter setTimeStyle:NSDateFormatterNoStyle];
        [dateFormatter setDateFormat:dateFormat];
    }
    
    [self.messagesTableView reloadData];
}

#pragma mark - Post messages

- (void)postMessage:(NSDictionary*)msgContent withLocalEventId:(NSString*)localEventId {
    MXMessageType msgType = msgContent[@"msgtype"];
    if (msgType) {
        // Check whether a temporary event has already been added for local echo (this happens on attachments)
        MXEvent *mxEvent = nil;
        if (localEventId) {
            // Update the temporary event with the actual msg content
            NSUInteger index = messages.count;
            while (index--) {
                mxEvent = [messages objectAtIndex:index];
                if ([mxEvent.eventId isEqualToString:localEventId]) {
                    mxEvent.content = msgContent;
                    // Refresh table display
                    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
                    [self.messagesTableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
                    break;
                }
            }
        } else {
            // Create a temporary event to displayed outgoing message (local echo)
            localEventId = [NSString stringWithFormat:@"%@%@", kLocalEchoEventIdPrefix, [[NSProcessInfo processInfo] globallyUniqueString]];
            mxEvent = [[MXEvent alloc] init];
            mxEvent.roomId = self.roomId;
            mxEvent.eventId = localEventId;
            mxEvent.eventType = MXEventTypeRoomMessage;
            mxEvent.type = kMXEventTypeStringRoomMessage;
            mxEvent.content = msgContent;
            mxEvent.userId = [MatrixHandler sharedHandler].userId;
            // Update table sources
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:messages.count inSection:0];
            [messages addObject:mxEvent];
            // Refresh table display (Disable animation during cells insertion to prevent flickering)
            [UIView setAnimationsEnabled:NO];
            [self.messagesTableView beginUpdates];
            if (indexPath.row > 0) {
                NSIndexPath *prevIndexPath = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:0];
                [self.messagesTableView reloadRowsAtIndexPaths:@[prevIndexPath] withRowAnimation:UITableViewRowAnimationNone];
            }
            [self.messagesTableView insertRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
            [self.messagesTableView endUpdates];
            [UIView setAnimationsEnabled:YES];
            
            [self scrollToBottomAnimated:NO];
        }
        
        // Send message to the room
        [[[MatrixHandler sharedHandler] mxRestClient] postMessageToRoom:self.roomId msgType:msgType content:mxEvent.content success:^(NSString *event_id) {
            // Update the temporary event with the actual event id
            NSUInteger index = messages.count;
            while (index--) {
                MXEvent *mxEvent = [messages objectAtIndex:index];
                if ([mxEvent.eventId isEqualToString:localEventId]) {
                    mxEvent.eventId = event_id;
                    // Refresh table display
                    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
                    [self.messagesTableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
                    break;
                }
            }
        } failure:^(NSError *error) {
            [self handleError:error forLocalEventId:localEventId];
        }];
    }
}

- (void)postTextMessage:(NSString*)msgTxt {
    MXMessageType msgType = kMXMessageTypeText;
    // Check whether the message is an emote
    if ([msgTxt hasPrefix:@"/me "]) {
        msgType = kMXMessageTypeEmote;
        // Remove "/me " string
        msgTxt = [msgTxt substringFromIndex:4];
    }
    
    [self postMessage:@{@"msgtype":msgType, @"body":msgTxt} withLocalEventId:nil];
}

- (NSString*)addLocalEventForAttachedImage:(UIImage*)image {
    // Create a temporary event to displayed outgoing message (local echo)
    NSString *localEventId = [NSString stringWithFormat:@"%@%@", kLocalEchoEventIdPrefix, [[NSProcessInfo processInfo] globallyUniqueString]];
    MXEvent *mxEvent = [[MXEvent alloc] init];
    mxEvent.roomId = self.roomId;
    mxEvent.eventId = localEventId;
    mxEvent.eventType = MXEventTypeRoomMessage;
    mxEvent.type = kMXEventTypeStringRoomMessage;
    // We store temporarily the image in cache, use the localId to build temporary url
    NSString *dummyURL = [NSString stringWithFormat:@"%@%@", kMediaManagerPrefixForDummyURL, localEventId];
    NSData *imageData = UIImageJPEGRepresentation(image, 0.5);
    NSString *cacheFilePath = [MediaManager cacheMediaData:imageData forURL:dummyURL mimeType:@"image/jpeg"];
    if (cacheFilePath) {
        if (tmpCachedAttachments == nil) {
            tmpCachedAttachments = [NSMutableArray array];
        }
        [tmpCachedAttachments addObject:cacheFilePath];
    }
    NSMutableDictionary *thumbnailInfo = [[NSMutableDictionary alloc] init];
    [thumbnailInfo setValue:@"image/jpeg" forKey:@"mimetype"];
    [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)image.size.width] forKey:@"w"];
    [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)image.size.height] forKey:@"h"];
    [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:imageData.length] forKey:@"size"];
    mxEvent.content = @{@"msgtype":@"m.image", @"thumbnail_info":thumbnailInfo, @"thumbnail_url":dummyURL};
    mxEvent.userId = [MatrixHandler sharedHandler].userId;
    
    // Update table sources
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:messages.count inSection:0];
    [messages addObject:mxEvent];
    
    // Refresh table display (Disable animation during cells insertion to prevent flickering)
    [UIView setAnimationsEnabled:NO];
    [self.messagesTableView beginUpdates];
    if (indexPath.row > 0) {
        NSIndexPath *prevIndexPath = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:0];
        [self.messagesTableView reloadRowsAtIndexPaths:@[prevIndexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
    [self.messagesTableView insertRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self.messagesTableView endUpdates];
    [UIView setAnimationsEnabled:YES];
    
    [self scrollToBottomAnimated:NO];
    return localEventId;
}

- (void)handleError:(NSError *)error forLocalEventId:(NSString *)localEventId {
    NSLog(@"Post message failed: %@", error);
    if (error) {
        // Alert user
        [[AppDelegate theDelegate] showErrorAsAlert:error];
    }
    
    // Update the temporary event with this local event id
    NSUInteger index = messages.count;
    while (index--) {
        MXEvent *mxEvent = [messages objectAtIndex:index];
        if ([mxEvent.eventId isEqualToString:localEventId]) {
            NSLog(@"Posted event: %@", mxEvent.description);
            mxEvent.eventId = kFailedEventId;
            // Refresh table display
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
            [self.messagesTableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
            break;
        }
    }
}

- (BOOL)isIRCStyleCommand:(NSString*)text{
    // Check whether the provided text may be an IRC-style command
    if ([text hasPrefix:@"/"] == NO || [text hasPrefix:@"//"] == YES) {
        return NO;
    }
    
    // Parse command line
    NSArray *components = [text componentsSeparatedByString:@" "];
    NSString *cmd = [components objectAtIndex:0];
    NSUInteger index = 1;
    
    if ([cmd isEqualToString:kCmdEmote]) {
        // post message as an emote
        [self postTextMessage:text];
    } else if ([text hasPrefix:kCmdChangeDisplayName]) {
        // Change display name
        NSString *displayName = [text substringFromIndex:kCmdChangeDisplayName.length + 1];
        // Remove white space from both ends
        displayName = [displayName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        if (displayName.length) {
            MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
            [mxHandler.mxRestClient setDisplayName:displayName success:^{
            } failure:^(NSError *error) {
                NSLog(@"Set displayName failed: %@", error);
                //Alert user
                [[AppDelegate theDelegate] showErrorAsAlert:error];
            }];
        } else {
            // Display cmd usage in text input as placeholder
            self.messageTextField.placeholder = @"Usage: /nick <display_name>";
        }
    } else if ([text hasPrefix:kCmdJoinRoom]) {
        // Join a room
        NSString *roomAlias = [text substringFromIndex:kCmdJoinRoom.length + 1];
        // Remove white space from both ends
        roomAlias = [roomAlias stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        // Check
        if (roomAlias.length) {
            // FIXME
            NSLog(@"Join Alias is not supported yet (%@)", text);
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"/join is not supported yet" message:nil delegate:nil cancelButtonTitle:@"OK" otherButtonTitles: nil];
            [alert show];
        } else {
            // Display cmd usage in text input as placeholder
            self.messageTextField.placeholder = @"Usage: /join <room_alias>";
        }
    } else {
        // Retrieve userId
        NSString *userId = nil;
        while (index < components.count) {
            userId = [components objectAtIndex:index++];
            if (userId.length) {
                // done
                break;
            }
            // reset
            userId = nil;
        }
        
        if ([cmd isEqualToString:kCmdKickUser]) {
            if (userId) {
                // Retrieve potential reason
                NSString *reason = nil;
                while (index < components.count) {
                    if (reason) {
                        reason = [NSString stringWithFormat:@"%@ %@", reason, [components objectAtIndex:index++]];
                    } else {
                        reason = [components objectAtIndex:index++];
                    }
                }
                // Kick the user
                MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
                [mxHandler.mxRestClient kickUser:userId fromRoom:self.roomId reason:reason success:^{
                } failure:^(NSError *error) {
                    NSLog(@"Kick user (%@) failed: %@", userId, error);
                    //Alert user
                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                self.messageTextField.placeholder = @"Usage: /kick <userId> [<reason>]";
            }
        } else if ([cmd isEqualToString:kCmdBanUser]) {
            if (userId) {
                // Retrieve potential reason
                NSString *reason = nil;
                while (index < components.count) {
                    if (reason) {
                        reason = [NSString stringWithFormat:@"%@ %@", reason, [components objectAtIndex:index++]];
                    } else {
                        reason = [components objectAtIndex:index++];
                    }
                }
                // Ban the user
                MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
                [mxHandler.mxRestClient banUser:userId inRoom:self.roomId reason:reason success:^{
                } failure:^(NSError *error) {
                    NSLog(@"Ban user (%@) failed: %@", userId, error);
                    //Alert user
                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                self.messageTextField.placeholder = @"Usage: /ban <userId> [<reason>]";
            }
        } else if ([cmd isEqualToString:kCmdUnbanUser]) {
            if (userId) {
                // Unban the user
                MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
                [mxHandler.mxRestClient unbanUser:userId inRoom:self.roomId success:^{
                } failure:^(NSError *error) {
                    NSLog(@"Unban user (%@) failed: %@", userId, error);
                    //Alert user
                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            } else {
                // Display cmd usage in text input as placeholder
                self.messageTextField.placeholder = @"Usage: /unban <userId>";
            }
        } else if ([cmd isEqualToString:kCmdSetUserPowerLevel]) {
            // Retrieve power level
            NSString *powerLevel = nil;
            while (index < components.count) {
                powerLevel = [components objectAtIndex:index++];
                if (powerLevel.length) {
                    // done
                    break;
                }
                // reset
                powerLevel = nil;
            }
            // Set power level
            if (userId && powerLevel) {
                // FIXME
                NSLog(@"Set user power level (/op) is not supported yet (%@)", userId);
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"/op is not supported yet" message:nil delegate:nil cancelButtonTitle:@"OK" otherButtonTitles: nil];
                [alert show];
            } else {
                // Display cmd usage in text input as placeholder
                self.messageTextField.placeholder = @"Usage: /op <userId> <power level>";
            }
        } else if ([cmd isEqualToString:kCmdResetUserPowerLevel]) {
            if (userId) {
                // Reset user power level
                // FIXME
                NSLog(@"Reset user power level (/deop) is not supported yet (%@)", userId);
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"/deop is not supported yet" message:nil delegate:nil cancelButtonTitle:@"OK" otherButtonTitles: nil];
                [alert show];
            } else {
                // Display cmd usage in text input as placeholder
                self.messageTextField.placeholder = @"Usage: /deop <userId>";
            }
        } else {
            NSLog(@"Unrecognised IRC-style command: %@", text);
            self.messageTextField.placeholder = [NSString stringWithFormat:@"Unrecognised IRC-style command: %@", cmd];
        }
    }
    return YES;
}

# pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    NSString *mediaType = [info objectForKey:UIImagePickerControllerMediaType];
    if ([mediaType isEqualToString:(NSString *)kUTTypeImage]) {
        UIImage *selectedImage = [info objectForKey:UIImagePickerControllerOriginalImage];
        if (selectedImage) {
            NSString * localEventId = [self addLocalEventForAttachedImage:selectedImage];
            // Upload image and its thumbnail
            MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
            NSUInteger thumbnailSize = ROOM_MESSAGE_CELL_MAX_TEXTVIEW_WIDTH - 2 * ROOM_MESSAGE_CELL_IMAGE_MARGIN;
            [mxHandler.mxRestClient uploadImage:selectedImage thumbnailSize:thumbnailSize timeout:30 success:^(NSDictionary *imageMessage) {
                // Send image
                [self postMessage:imageMessage withLocalEventId:localEventId];
            } failure:^(NSError *error) {
                [self handleError:error forLocalEventId:localEventId];
            }];
        }
    } else if ([mediaType isEqualToString:(NSString *)kUTTypeMovie]) {
        NSURL* selectedVideo = [info objectForKey:UIImagePickerControllerMediaURL];
        if (selectedVideo) {
            // Create video thumbnail
            MPMoviePlayerController* moviePlayerController = [[MPMoviePlayerController alloc] initWithContentURL:selectedVideo];
            if (moviePlayerController) {
                [moviePlayerController setShouldAutoplay:NO];
                UIImage* videoThumbnail = [moviePlayerController thumbnailImageAtTime:(NSTimeInterval)1 timeOption:MPMovieTimeOptionNearestKeyFrame];
                [moviePlayerController stop];
                moviePlayerController = nil;
                
                if (videoThumbnail) {
                    // Prepare video thumbnail description
                    NSUInteger thumbnailSize = ROOM_MESSAGE_CELL_MAX_TEXTVIEW_WIDTH - 2 * ROOM_MESSAGE_CELL_IMAGE_MARGIN;
                    UIImage *thumbnail = [MediaManager resize:videoThumbnail toFitInSize:CGSizeMake(thumbnailSize, thumbnailSize)];
                    NSMutableDictionary *thumbnailInfo = [[NSMutableDictionary alloc] init];
                    [thumbnailInfo setValue:@"image/jpeg" forKey:@"mimetype"];
                    [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)thumbnail.size.width] forKey:@"w"];
                    [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)thumbnail.size.height] forKey:@"h"];
                    NSData *thumbnailData = UIImageJPEGRepresentation(thumbnail, 0.9);
                    [thumbnailInfo setValue:[NSNumber numberWithUnsignedInteger:thumbnailData.length] forKey:@"size"];
                    
                    // Create the local event displayed during uploading
                    NSString * localEventId = [self addLocalEventForAttachedImage:thumbnail];
                    
                    // Upload thumbnail
                    MatrixHandler *mxHandler = [MatrixHandler sharedHandler];
                    [mxHandler.mxRestClient uploadContent:thumbnailData mimeType:@"image/jpeg" timeout:30 success:^(NSString *url) {
                        // Prepare content of attached video
                        NSMutableDictionary *videoContent = [[NSMutableDictionary alloc] init];
                        NSMutableDictionary *videoInfo = [[NSMutableDictionary alloc] init];
                        [videoContent setValue:@"m.video" forKey:@"msgtype"];
                        [videoInfo setValue:url forKey:@"thumbnail_url"];
                        [videoInfo setValue:thumbnailInfo forKey:@"thumbnail_info"];
                        
                        // Convert video container to mp4
                        AVURLAsset* videoAsset = [AVURLAsset URLAssetWithURL:selectedVideo options:nil];
                        AVAssetExportSession *exportSession = [AVAssetExportSession exportSessionWithAsset:videoAsset presetName:AVAssetExportPresetMediumQuality];
                        // Set output URL
                        NSString * outputFileName = [NSString stringWithFormat:@"%.0f.mp4",[[NSDate date] timeIntervalSince1970]];
                        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
                        NSString *cacheRoot = [paths objectAtIndex:0];
                        NSURL *tmpVideoLocation = [NSURL fileURLWithPath:[cacheRoot stringByAppendingPathComponent:outputFileName]];
                        exportSession.outputURL = tmpVideoLocation;
                        // Check supported output file type
                        NSArray *supportedFileTypes = exportSession.supportedFileTypes;
                        if ([supportedFileTypes containsObject:AVFileTypeMPEG4]) {
                            exportSession.outputFileType = AVFileTypeMPEG4;
                            [videoInfo setValue:@"video/mp4" forKey:@"mimetype"];
                        } else {
                            NSLog(@"Unexpected case: MPEG-4 file format is not supported");
                            // we send QuickTime movie file by default
                            exportSession.outputFileType = AVFileTypeQuickTimeMovie;
                            [videoInfo setValue:@"video/quicktime" forKey:@"mimetype"];
                        }
                        // Export video file and send it
                        [exportSession exportAsynchronouslyWithCompletionHandler:^{
                            // Check status
                            if ([exportSession status] == AVAssetExportSessionStatusCompleted) {
                                AVURLAsset* asset = [AVURLAsset URLAssetWithURL:tmpVideoLocation
                                                                        options:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                                 [NSNumber numberWithBool:YES],
                                                                                 AVURLAssetPreferPreciseDurationAndTimingKey,
                                                                                 nil]
                                                     ];
                                
                                [videoInfo setValue:[NSNumber numberWithDouble:(1000 * CMTimeGetSeconds(asset.duration))] forKey:@"duration"];
                                NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
                                if (videoTracks.count > 0) {
                                    AVAssetTrack *videoTrack = [videoTracks objectAtIndex:0];
                                    CGSize videoSize = videoTrack.naturalSize;
                                    [videoInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)videoSize.width] forKey:@"w"];
                                    [videoInfo setValue:[NSNumber numberWithUnsignedInteger:(NSUInteger)videoSize.height] forKey:@"h"];
                                }
                                
                                // Upload the video
                                NSData *videoData = [NSData dataWithContentsOfURL:tmpVideoLocation];
                                [[NSFileManager defaultManager] removeItemAtPath:[tmpVideoLocation path] error:nil];
                                if (videoData) {
                                    if (videoData.length < UPLOAD_FILE_SIZE) {
                                        [videoInfo setValue:[NSNumber numberWithUnsignedInteger:videoData.length] forKey:@"size"];
                                        [mxHandler.mxRestClient uploadContent:videoData mimeType:videoInfo[@"mimetype"] timeout:30 success:^(NSString *url) {
                                            [videoContent setValue:url forKey:@"url"];
                                            [videoContent setValue:videoInfo forKey:@"info"];
                                            [videoContent setValue:@"Video" forKey:@"body"];
                                            [self postMessage:videoContent withLocalEventId:localEventId];
                                        } failure:^(NSError *error) {
                                            [self handleError:error forLocalEventId:localEventId];
                                        }];
                                    } else {
                                        NSLog(@"Video is too large");
                                        [self handleError:nil forLocalEventId:localEventId];
                                    }
                                } else {
                                    NSLog(@"Attach video failed: no data");
                                    [self handleError:nil forLocalEventId:localEventId];
                                }
                            }
                            else {
                                NSLog(@"Video export failed: %d", [exportSession status]);
                                // remove tmp file (if any)
                                [[NSFileManager defaultManager] removeItemAtPath:[tmpVideoLocation path] error:nil];
                                [self handleError:nil forLocalEventId:localEventId];
                            }
                        }];
                    } failure:^(NSError *error) {
                        NSLog(@"Video thumbnail upload failed");
                        [self handleError:error forLocalEventId:localEventId];
                    }];
                }
            }
        }
    }

    [self dismissMediaPicker];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [self dismissMediaPicker];
}

- (void)dismissMediaPicker {
    [[AppDelegate theDelegate].masterTabBarController dismissMediaPicker];
}
@end
