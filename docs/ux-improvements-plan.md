# UX/UI Improvements Plan for Coffee Bot

**Date:** 2026-03-06
**Status:** Planning

## Overview

This document outlines the UX/UI improvements for Coffee Bot Telegram interface to:
- Reduce order time
- Increase average check
- Lower user errors
- Improve barista workflow
- Better navigation

## Implementation Phases

### Phase 1: Main Menu Redesign
- Add interactive main menu after /start
- Categories: Coffee, Desserts, Tea, Add-ons
- Quick access: Popular, Cart, My Orders
- Max 2-3 buttons per row

### Phase 2: Category Navigation
- Show items as inline buttons with prices
- Back and Cart navigation on every screen
- Item count and category name in header

### Phase 3: Product Cards
- Item details view with description
- Add to Cart button
- Add-ons button
- Back navigation

### Phase 4: Add-ons Selection
- Multiple selection for add-ons (syrups, milk types)
- Running total display
- Done button to confirm

### Phase 5: Cart Screen
- Item list with quantities
- Add-ons shown separately
- Running total always visible
- Actions: Add more, Clear, Checkout

### Phase 6: Quick Reorder
- Show previous order option on main menu
- One-click reorder functionality

### Phase 7: Popular Items
- Featured items section in main menu
- Quick access to best-selling items

### Phase 8: Upsell Flow
- Suggest desserts after coffee order
- Add/No thanks buttons

### Phase 9: Order Status Messages
- Clear status indicators with emojis
- ETA display for preparation time
- Progress updates

### Phase 10: Barista Panel
- Order queue sorted by time
- Time waiting indicators (warning >5min, critical >10min)
- Claim and Complete actions

### Phase 11: Navigation
- Back button on every screen
- Main Menu shortcut
- Cart shortcut

## Technical Requirements
- All interactions via inline keyboard buttons
- No text input required from users
- Maximum 3 buttons per row
- Emoji for visual categories
- Compact message structure

## Success Metrics
- Order completion in 3-4 clicks
- Reduced order errors
- Faster barista processing
- Higher average order value (upsell)
