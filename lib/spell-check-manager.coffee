class SpellCheckerManager
  checkers: []
  locales: []
  localePaths: []
  useLocales: false
  localeCheckers: null
  knownWords: []
  addKnownWords: false
  knownWordsChecker: null

  addPluginChecker: (checker) ->
    console.log "spell-check-test: addPluginChecker:", checker
    @addSpellChecker checker
  addSpellChecker: (checker) ->
    console.log "spell-check-test: addSpellChecker:", checker
    @checkers.push checker

  removeSpellChecker: (spellChecker) ->
    @checkers = @checkers.filter (plugin) -> plugin isnt spellChecker

  check: (args, text) ->
    # Make sure our deferred initialization is done.
    @init()

    # We need a couple packages.
    multirange = require 'multi-integer-range'

    # For every registered spellchecker, we need to find out the ranges in the
    # text that the checker confirms are correct or indicates is a misspelling.
    # We keep these as separate lists since the different checkers may indicate
    # the same range for either and we need to be able to remove confirmed words
    # from the misspelled ones.
    correct = new multirange.MultiRange([])
    incorrects = []

    for checker in @checkers
      # We only care if this plugin contributes to checking spelling.
      if not checker.isEnabled() or not checker.providesSpelling(args)
        continue

      # Get the results which includes positive (correct) and negative (incorrect)
      # ranges.
      results = checker.check(args, text)

      if results.correct
        for range in results.correct
          correct.appendRange(range.start, range.end)

      if results.incorrect
        newIncorrect = new multirange.MultiRange([])
        incorrects.push(newIncorrect)

        for range in results.incorrect
          newIncorrect.appendRange(range.start, range.end)

    # If we don't have any incorrect spellings, then there is nothing to worry
    # about, so just return and stop processing.
    misspellings = []

    if incorrects.length == 0
      return {id: args.id, misspellings}

    # Build up an intersection of all the incorrect ranges. We only treat a word
    # as being incorrect if *every* checker that provides negative values treats
    # it as incorrect. We know there are at least one item in this list, so pull
    # that out. If that is the only one, we don't have to do any additional work,
    # otherwise we compare every other one against it, removing any elements
    # that aren't an intersection which (hopefully) will produce a smaller list
    # with each iteration.
    intersection = null
    index = 1

    for incorrect in incorrects
      if intersection is null
        intersection = incorrect
      else
        intersection.intersect(incorrects[index])

    # If we have no intersection, then nothing to report as a problem.
    if intersection.length is 0
      return {id: args.id, misspellings}

    # Remove all of the confirmed correct words from the resulting incorrect
    # list. This allows us to have correct-only providers as opposed to only
    # incorrect providers.
    if correct.ranges.length > 0
      intersection.subtract(correct)

    # Convert the text ranges (index into the string) into Atom buffer
    # coordinates ( row and column).
    row = 0
    rangeIndex = 0
    lineBeginIndex = 0
    while lineBeginIndex < text.length and rangeIndex < intersection.ranges.length
      # Figure out where the next line break is. If we hit -1, then we make sure
      # it is a higher number so our < comparisons work properly.
      lineEndIndex = text.indexOf('\n', lineBeginIndex)
      if lineEndIndex is -1
        lineEndIndex = Infinity

      # Loop through and get all the ranegs for this line.
      loop
        range = intersection.ranges[rangeIndex]
        if range and range[0] < lineEndIndex
          # Figure out the character range of this line. We need this because
          # @addMisspellings doesn't handle jumping across lines easily and the
          # use of the number ranges is inclusive.
          lineRange = new multirange.MultiRange([]).appendRange(lineBeginIndex, lineEndIndex)
          rangeRange = new multirange.MultiRange([]).appendRange(range[0], range[1])
          lineRange.intersect(rangeRange)

          # The range we have here includes whitespace between two concurrent
          # tokens ("zz zz zz" shows up as a single misspelling). The original
          # version would split the example into three separate ones, so we
          # do the same thing, but only for the ranges within the line.
          @addMisspellings(misspellings, row, lineRange.ranges[0], lineBeginIndex, text)

          # If this line is beyond the limits of our current range, we move to
          # the next one, otherwise we loop again to reuse this range against
          # the next line.
          if lineEndIndex >= range[1]
            rangeIndex++
          else
            break
        else
          break

      lineBeginIndex = lineEndIndex + 1
      row++

    # Return the resulting misspellings.
    {id: args.id, misspellings: misspellings}

  suggest: (args, word) ->
    # Make sure our deferred initialization is done.
    @init()

    # Gather up a list of corrections and put them into a custom object that has
    # the priority of the plugin, the index in the results, and the word itself.
    # We use this to intersperse the results together to avoid having the
    # preferred answer for the second plugin below the least preferred of the
    # first.
    suggestions = []

    for checker in @checkers
      # We only care if this plugin contributes to checking to suggestions.
      if not checker.isEnabled() or not checker.providesSuggestions(args)
        continue

      # Get the suggestions for this word.
      index = 0
      priority = checker.getPriority()

      for suggestion in checker.suggest(args, word)
        suggestions.push { isSuggestion: true, priority: priority, index: index++, suggestion: suggestion, label: suggestion }

    # Once we have the suggestions, then sort them to intersperse the results.
    keys = Object.keys(suggestions).sort (key1, key2) ->
      value1 = suggestions[key1]
      value2 = suggestions[key2]
      weight1 = value1.priority + value1.index
      weight2 = value2.priority + value2.index

      if weight1 != weight2
        return weight1 - weight2

      return value1.suggestion.localeCompare(value2.suggestion)

    # Go through the keys and build the final list of suggestions. As we go
    # through, we also want to remove duplicates.
    results = []
    seen = []
    for key in keys
      s = suggestions[key]
      if seen.hasOwnProperty s.suggestion
        continue
      results.push s
      seen[s.suggestion] = 1

    # We also grab the "add to dictionary" listings.
    that = this
    keys = Object.keys(@checkers).sort (key1, key2) ->
      value1 = that.checkers[key1]
      value2 = that.checkers[key2]
      value1.getPriority() - value2.getPriority()

    for key in keys
      # We only care if this plugin contributes to checking to suggestions.
      checker = @checkers[key]
      if not checker.isEnabled() or not checker.providesAdding(args)
        continue

      # Add all the targets to the list.
      targets = checker.getAddingTargets args
      for target in targets
        target.plugin = checker
        target.word = word
        target.isSuggestion = false
        results.push target

    # Return the resulting list of options.
    results

  addMisspellings: (misspellings, row, range, lineBeginIndex, text) ->
    # Get the substring of text, if there is no space, then we can just return
    # the entire result.
    substring = text.substring(range[0], range[1])

    if /\s+/.test substring
      # We have a space, to break it into individual components and push each
      # one to the misspelling list.
      parts = substring.split /(\s+)/
      substringIndex = 0
      for part in parts
        if not /\s+/.test part
          markBeginIndex = range[0] - lineBeginIndex + substringIndex
          markEndIndex = markBeginIndex + part.length
          misspellings.push([[row, markBeginIndex], [row, markEndIndex]])

        substringIndex += part.length

      return

    # There were no spaces, so just return the entire list.
    misspellings.push([
      [row, range[0] - lineBeginIndex],
      [row, range[1] - lineBeginIndex]
    ])

  init: ->
    # See if we need to initialize the system checkers.
    if @localeCheckers is null
      # Initialize the collection. If we aren't using any, then stop doing anything.
      console.log "spell-check-test: loading locales", @useLocales, @locales
      @localeCheckers = []

      if @useLocales
        # If we have a blank location, use the default based on the navigator.
        if not @locales.length
          defaultLocale = process.env.LANG;
          if defaultLocale
            @locales = [defaultLocale.split('.')[0]]

        # If we can't figure out the language from the process, check the browser.
        if not @locales.length
          defaultLocale = navigator.language
          if defaultLocale
            @locales = [defaultLocale]

        # If we still can't figure it out, use US English.
        if not @locales.length
          @locales = ['en_US']

        # Go through the new list and create new locale checkers.
        SystemChecker = require "./system-checker"
        for locale in @locales
          checker = new SystemChecker locale, @localePaths
          @addSpellChecker checker
          @localeCheckers.push checker

    # See if we need to reload the known words.
    if @knownWordsChecker is null
      console.log "spell-check-test: loading known words"
      KnownWordsChecker = require './known-words-checker.coffee'
      @knownWordsChecker = new KnownWordsChecker @knownWords
      @knownWordsChecker.enableAdd = @addKnownWords
      @addSpellChecker @knownWordsChecker

  deactivate: ->
    @checkers = []
    @locales = []
    @localePaths = []
    @useLocales=  false
    @localeCheckers = null
    @knownWords = []
    @addKnownWords = false
    @knownWordsChecker = null

  reloadLocales: ->
    if @localeCheckers
      console.log "spell-check-test: unloading locales"
      for localeChecker in @localeCheckers
        @removeSpellChecker localeChecker
      @localeCheckers = null

  reloadKnownWords: ->
    if @knownWordsChecker
      console.log "spell-check-test: unloading known words"
      @removeSpellChecker @knownWordsChecker
      @knownWordsChecker = null

manager = new SpellCheckerManager
module.exports = manager

#    KnownWordsChecker = require './known-words-checker.coffee'
#    knownWords = atom.config.get('spell-check-test.knownWords')
#    addKnownWords = atom.config.get('spell-check-test.addKnownWords')