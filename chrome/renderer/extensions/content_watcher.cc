// Copyright (c) 2012 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chrome/renderer/extensions/content_watcher.h"

#include "chrome/common/extensions/extension_messages.h"
#include "content/public/renderer/render_view.h"
#include "content/public/renderer/render_view_visitor.h"
#include "third_party/WebKit/public/web/WebDocument.h"
#include "third_party/WebKit/public/web/WebElement.h"
#include "third_party/WebKit/public/web/WebFrame.h"
#include "third_party/WebKit/public/web/WebScriptBindings.h"
#include "third_party/WebKit/public/web/WebView.h"

namespace extensions {

using WebKit::WebString;
using WebKit::WebVector;
using WebKit::WebView;

ContentWatcher::ContentWatcher() {}
ContentWatcher::~ContentWatcher() {}

void ContentWatcher::OnWatchPages(
    const std::vector<std::string>& new_css_selectors_utf8) {
  WebKit::WebVector<WebKit::WebString> new_css_selectors(
      new_css_selectors_utf8.size());
  bool changed = new_css_selectors.size() != css_selectors_.size();
  for (size_t i = 0; i < new_css_selectors.size(); ++i) {
    new_css_selectors[i] =
        WebKit::WebString::fromUTF8(new_css_selectors_utf8[i]);
    if (!changed && new_css_selectors[i] != css_selectors_[i])
      changed = true;
  }

  if (!changed)
    return;

  css_selectors_.swap(new_css_selectors);

  // Tell each frame's document about the new set of watched selectors. These
  // will trigger calls to DidMatchCSS after Blink has a chance to apply the new
  // style, which will in turn notify the browser about the changes.
  struct WatchSelectors : public content::RenderViewVisitor {
    explicit WatchSelectors(const WebVector<WebString>& css_selectors)
        : css_selectors_(css_selectors) {}

    virtual bool Visit(content::RenderView* view) OVERRIDE {
      for (WebKit::WebFrame* frame = view->GetWebView()->mainFrame(); frame;
           frame = frame->traverseNext(/*wrap=*/false))
        frame->document().watchCSSSelectors(css_selectors_);

      return true;  // Continue visiting.
    }

    const WebVector<WebString>& css_selectors_;
  };
  WatchSelectors visitor(css_selectors_);
  content::RenderView::ForEach(&visitor);
}

void ContentWatcher::DidCreateDocumentElement(WebKit::WebFrame* frame) {
  frame->document().watchCSSSelectors(css_selectors_);
}

void ContentWatcher::DidMatchCSS(
    WebKit::WebFrame* frame,
    const WebVector<WebString>& newly_matching_selectors,
    const WebVector<WebString>& stopped_matching_selectors) {
  std::set<std::string>& frame_selectors = matching_selectors_[frame];
  for (size_t i = 0; i < stopped_matching_selectors.size(); ++i)
    frame_selectors.erase(stopped_matching_selectors[i].utf8());
  for (size_t i = 0; i < newly_matching_selectors.size(); ++i)
    frame_selectors.insert(newly_matching_selectors[i].utf8());

  if (frame_selectors.empty())
    matching_selectors_.erase(frame);

  NotifyBrowserOfChange(frame);
}

void ContentWatcher::NotifyBrowserOfChange(
    WebKit::WebFrame* changed_frame) const {
  WebKit::WebFrame* const top_frame = changed_frame->top();
  const WebKit::WebSecurityOrigin top_origin =
      top_frame->document().securityOrigin();
  // Want to aggregate matched selectors from all frames where an
  // extension with access to top_origin could run on the frame.
  if (!top_origin.canAccess(changed_frame->document().securityOrigin())) {
    // If the changed frame can't be accessed by the top frame, then
    // no change in it could affect the set of selectors we'd send back.
    return;
  }

  std::set<base::StringPiece> transitive_selectors;
  for (WebKit::WebFrame* frame = top_frame; frame;
       frame = frame->traverseNext(/*wrap=*/false)) {
    if (top_origin.canAccess(frame->document().securityOrigin())) {
      std::map<WebKit::WebFrame*, std::set<std::string> >::const_iterator
          frame_selectors = matching_selectors_.find(frame);
      if (frame_selectors != matching_selectors_.end()) {
        transitive_selectors.insert(frame_selectors->second.begin(),
                                    frame_selectors->second.end());
      }
    }
  }
  std::vector<std::string> selector_strings;
  for (std::set<base::StringPiece>::const_iterator
           it = transitive_selectors.begin();
       it != transitive_selectors.end(); ++it)
    selector_strings.push_back(it->as_string());
  content::RenderView* view =
      content::RenderView::FromWebView(top_frame->view());
  view->Send(new ExtensionHostMsg_OnWatchedPageChange(
      view->GetRoutingID(), selector_strings));
}

}  // namespace extensions
