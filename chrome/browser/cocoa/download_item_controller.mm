// Copyright (c) 2009 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "chrome/browser/cocoa/download_item_controller.h"

#include "app/gfx/text_elider.h"
#include "app/l10n_util_mac.h"
#include "base/mac_util.h"
#include "base/sys_string_conversions.h"
#import "chrome/browser/cocoa/download_item_cell.h"
#include "chrome/browser/cocoa/download_item_mac.h"
#import "chrome/browser/cocoa/download_shelf_controller.h"
#include "chrome/browser/download/download_item_model.h"
#include "chrome/browser/download/download_shelf.h"
#include "chrome/browser/download/download_util.h"
#include "grit/generated_resources.h"

static const int kTextWidth = 140;            // Pixels

// A class for the chromium-side part of the download shelf context menu.

class DownloadShelfContextMenuMac : public DownloadShelfContextMenu {
 public:
  DownloadShelfContextMenuMac(BaseDownloadItemModel* model)
      : DownloadShelfContextMenu(model) { }

  using DownloadShelfContextMenu::ExecuteItemCommand;
  using DownloadShelfContextMenu::ItemIsChecked;
  using DownloadShelfContextMenu::IsItemCommandEnabled;

  using DownloadShelfContextMenu::SHOW_IN_FOLDER;
  using DownloadShelfContextMenu::OPEN_WHEN_COMPLETE;
  using DownloadShelfContextMenu::ALWAYS_OPEN_TYPE;
  using DownloadShelfContextMenu::CANCEL;
  using DownloadShelfContextMenu::REMOVE_ITEM;
};

@interface DownloadItemController (Private)
- (void)setState:(DownoadItemState)state;
@end

// Implementation of DownloadItemController

@implementation DownloadItemController

- (id)initWithModel:(BaseDownloadItemModel*)downloadModel
              shelf:(DownloadShelfController*)shelf {
  if ((self = [super initWithNibName:@"DownloadItem"
                              bundle:mac_util::MainAppBundle()])) {
    // Must be called before [self view], so that bridge_ is set in awakeFromNib
    bridge_.reset(new DownloadItemMac(downloadModel, self));
    menuBridge_.reset(new DownloadShelfContextMenuMac(downloadModel));

    shelf_ = shelf;
    state_ = kNormal;
    creationTime_ = base::Time::Now();
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [[self view] removeFromSuperview];
  [super dealloc];
}

- (void)awakeFromNib {
  [self setStateFromDownload:bridge_->download_model()];
  bridge_->LoadIcon();
}

- (void)setStateFromDownload:(BaseDownloadItemModel*)downloadModel {
  DCHECK_EQ(bridge_->download_model(), downloadModel);

  // Handle dangerous downloads.
  if (downloadModel->download()->safety_state() == DownloadItem::DANGEROUS) {
    [self setState:kDangerous];

    // Set label.
    NSFont* font = [dangerousDownloadLabel_ font];
    gfx::Font fontChr = gfx::Font::CreateFont(
        base::SysNSStringToWide([font fontName]), [font pointSize]);
    string16 elidedFilename = WideToUTF16(ElideFilename(
        downloadModel->download()->original_name(), fontChr, kTextWidth));
    NSString* dangerousWarning =
        l10n_util::GetNSStringFWithFixup(IDS_PROMPT_DANGEROUS_DOWNLOAD,
                                         elidedFilename);
    [dangerousDownloadLabel_ setStringValue:dangerousWarning];
    return;
  }

  // Set the correct popup menu.
  if (downloadModel->download()->state() == DownloadItem::COMPLETE)
    currentMenu_ = completeDownloadMenu_;
  else
    currentMenu_ = activeDownloadMenu_;

  [progressView_ setMenu:currentMenu_];  // for context menu
  [cell_ setStateFromDownload:downloadModel];
}

- (void)setIcon:(NSImage*)icon {
  [cell_ setImage:icon];
}

- (void)remove {
  // We are deleted after this!
  [shelf_ remove:self];
}

- (void)updateVisibility:(id)sender {
  // TODO(thakis): Make this prettier, by fading the items out or overlaying
  // the partial visible one with a horizontal alpha gradient -- crbug.com/17830
  NSView* view = [self view];
  NSRect containerFrame = [[view superview] frame];
  [view setHidden:(NSMaxX([view frame]) > NSWidth(containerFrame))];
}

- (IBAction)handleButtonClick:(id)sender {
  if ([cell_ isButtonPartPressed]) {
    DownloadItem* download = bridge_->download_model()->download();
    if (download->state() == DownloadItem::IN_PROGRESS)
      download->set_open_when_complete(!download->open_when_complete());
    else if (download->state() == DownloadItem::COMPLETE)
      download_util::OpenDownload(download);
  } else {
    [NSMenu popUpContextMenu:currentMenu_
               withEvent:[NSApp currentEvent]
                 forView:progressView_];
  }
}

- (NSSize)preferredSize {
  if (state_ == kNormal)
    return [progressView_ frame].size;
  DCHECK_EQ(kDangerous, state_);
  return [dangerousDownloadView_ frame].size;
}

- (DownloadItem*)download {
  return bridge_->download_model()->download();
}

- (void)clearDangerousMode {
  [self setState:kNormal];
}

- (BOOL)isDangerousMode {
  return state_ == kDangerous;
}

- (void)setState:(DownoadItemState)state {
  if (state_ == state)
    return;
  state_ = state;
  if (state_ == kNormal) {
    [progressView_ setHidden:NO];
    [dangerousDownloadView_ setHidden:YES];
  } else {
    DCHECK_EQ(kDangerous, state_);
    [progressView_ setHidden:YES];
    [dangerousDownloadView_ setHidden:NO];
  }
  [shelf_ layoutItems];
}

- (IBAction)saveDownload:(id)sender {
  // The user has confirmed a dangerous download.  We record how quickly the
  // user did this to detect whether we're being clickjacked.
  UMA_HISTOGRAM_LONG_TIMES("clickjacking.save_download",
                           base::Time::Now() - creationTime_);
  // This will change the state and notify us.
  bridge_->download_model()->download()->manager()->DangerousDownloadValidated(
      bridge_->download_model()->download());
}

- (IBAction)discardDownload:(id)sender {
  UMA_HISTOGRAM_LONG_TIMES("clickjacking.discard_download",
                           base::Time::Now() - creationTime_);
  if (bridge_->download_model()->download()->state() ==
      DownloadItem::IN_PROGRESS)
    bridge_->download_model()->download()->Cancel(true);
  bridge_->download_model()->download()->Remove(true);
  // WARNING: we are deleted at this point.  Don't access 'this'.
}


// Sets the enabled and checked state of a particular menu item for this
// download. We translate the NSMenuItem selection to menu selections understood
// by the non platform specific download context menu.
- (BOOL)validateMenuItem:(NSMenuItem *)item {
  SEL action = [item action];

  int actionId = 0;
  if (action == @selector(handleOpen:)) {
    actionId = DownloadShelfContextMenuMac::OPEN_WHEN_COMPLETE;
  } else if (action == @selector(handleAlwaysOpen:)) {
    actionId = DownloadShelfContextMenuMac::ALWAYS_OPEN_TYPE;
  } else if (action == @selector(handleReveal:)) {
    actionId = DownloadShelfContextMenuMac::SHOW_IN_FOLDER;
  } else if (action == @selector(handleRemove:)) {
    actionId = DownloadShelfContextMenuMac::REMOVE_ITEM;
  } else if (action == @selector(handleCancel:)) {
    actionId = DownloadShelfContextMenuMac::CANCEL;
  } else {
    NOTREACHED();
    return YES;
  }

  if (menuBridge_->ItemIsChecked(actionId))
    [item setState:NSOnState];
  else
    [item setState:NSOffState];

  return menuBridge_->IsItemCommandEnabled(actionId) ? YES : NO;
}

- (IBAction)handleOpen:(id)sender {
  menuBridge_->ExecuteItemCommand(
      DownloadShelfContextMenuMac::OPEN_WHEN_COMPLETE);
}

- (IBAction)handleAlwaysOpen:(id)sender {
  menuBridge_->ExecuteItemCommand(
      DownloadShelfContextMenuMac::ALWAYS_OPEN_TYPE);
}

- (IBAction)handleReveal:(id)sender {
  menuBridge_->ExecuteItemCommand(DownloadShelfContextMenuMac::SHOW_IN_FOLDER);
}

- (IBAction)handleRemove:(id)sender {
  menuBridge_->ExecuteItemCommand(DownloadShelfContextMenuMac::REMOVE_ITEM);
}

- (IBAction)handleCancel:(id)sender {
  menuBridge_->ExecuteItemCommand(DownloadShelfContextMenuMac::CANCEL);
}

@end
