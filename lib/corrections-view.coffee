{Range} = require 'atom'
{SelectListView} = require 'atom-space-pen-views'

module.exports =
class CorrectionsView extends SelectListView
  initialize: (@editor, @corrections, @marker) ->
    super
    @addClass('corrections popover-list')
    @attach()

  attach: ->
    @setItems(@corrections)
    @overlayDecoration = @editor.decorateMarker(@marker, type: 'overlay', item: this)

  attached: ->
    @storeFocusedElement()
    @focusFilterEditor()

  destroy: ->
    @cancel()
    @remove()

  confirmed: (item) ->
    @cancel()
    return unless item
    @editor.transact =>
      if item.hasOwnProperty "suggestion"
        # Update the buffer with the correction.
        @editor.setSelectedBufferRange(@marker.getRange())
        @editor.insertText(correction)
      if item.hasOwnProperty "label"
        # Send the "add" request to the plugin.
        item.plugin.add @editor.buffer, item

  cancelled: ->
    @overlayDecoration.destroy()
    @restoreFocus()

  viewForItem: (item) ->
    element = document.createElement "li"
    if item.hasOwnProperty "suggestion"
      # This is a word replacement suggestion.
      element.textContent = item.suggestion
    if item.hasOwnProperty "label"
      # This is an operation such as add word.
      em = document.createElement "em"
      em.textContent = item.label
      element.appendChild em
    element

  selectNextItemView: ->
    super
    false

  selectPreviousItemView: ->
    super
    false

  getEmptyMessage: (itemCount) ->
    if itemCount is 0
      'No corrections'
    else
      super
