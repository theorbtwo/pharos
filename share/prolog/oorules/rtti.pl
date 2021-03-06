% ============================================================================================
% Runtime type information reasoning.
% ============================================================================================

bogusName('MISSING').

% Given a TypeDescriptor address, return Name.  Return a "bogus" nbame if needed to prevent
% this predicate from failing since it's hard to debug when the failure is caused by attempting
% to report the details of a problem.
:- table rTTIName/2 as opaque.
rTTIName(TDA, Name) :-
    rTTITypeDescriptor(TDA, _TIVTable, Name, _DName) -> true ; bogusName(Name).

:- table rTTITDA2VFTable/2 as opaque.
rTTITDA2VFTable(TDA, VFTable) :-
    rTTITypeDescriptor(TDA, _TIVTable, _Name, _DName),
    rTTICompleteObjectLocator(Pointer, _COLA, TDA, _CHDA, _Offset, _O2),
    VFTable is Pointer + 4.

% This tule must be table incremental because of the find() clause.
:- table rTTITDA2Class/2 as incremental.
rTTITDA2Class(TDA, Class) :-
    % First turn the TypeDescriptor address into a VFTable address.
    rTTITypeDescriptor(TDA, _TIVTable, _Name, _DName),
    rTTICompleteObjectLocator(Pointer, _COLA, TDA, _CHDA, Offset, _O2),
    VFTable is Pointer + 4,
    % Now to turn the VFTable address into a class ID.  Presumably there's at least one method
    % that write the VFTable pointer.  We only want the one installed at offset zero because
    % we're looking for the constructor of the class associated with the VFTable.
    factVFTableWrite(_Insn, Method, 0, VFTable),
    % But if that method is confused about which VFTable is the primary, don't use that method
    % to determine the correct class.   Presumably there will be another non-conflicted method
    % that will just produce the correct answer.
    not(possibleVFTableOverwrite(_, _, Method, Offset, _VFTable1, _VFTable2)),
    % Finally, get the current class representative for that method.

    % Because of inlining and optimization, destructors should not be used for correlating TDAs
    % and VFTables.   See the commentary in mergeClasses().
    not(factNOTConstructor(Method)),

    find(Method, Class).

% In each class definition, there's supposed to be one circular loop of pointers that describes
% casting a class into itself.  This rule finds that set of pointers, tying together a type
% descriptor, a complete object locator, a class heirarchy descriptor, a base class descriptor,
% a primary virtual function table address, and a class name.

:- table rTTISelfRef/6 as opaque.
rTTISelfRef(TDA, COLA, CHDA, BCDA, VFTable, Name) :-
    rTTITypeDescriptor(TDA, _TIVTable, Name, _DName),
    rTTICompleteObjectLocator(Pointer, COLA, TDA, CHDA, _O1, _CDOffset),
    % CDOffset is usually zero, but we've found at least one case (mysqld) where it was 4.  It
    % appears that this rule is too strict if it limits the CDOffset to zero.
    VFTable is Pointer + 4,
    rTTIClassHierarchyDescriptor(CHDA, _HierarchyAttributes, Bases),
    member(BCDA, Bases),

    %logtrace('Evaluating TDA='), logtrace(TDA), logtrace(' COLA='), logtrace(COLA),
    %logtrace(' CHDA='), logtrace(CHDA), logtrace(' BCDA='), logtraceln(BCDA),

    % Silly Prolog thinks unsigned numbers don't exist.  That's so 1978!
    Big is 0x7fffffff,
    NegativeOne is Big * 2 + 1,

    % We're primarly checking that TDA points back to the original type descriptor.  But also,
    % if (and only if) BaseAttributes is has the bcd_has_CHD_pointer bit set, then the optional
    % BCHDA field should also point to the same class hierarchy descriptor.
    rTTIBaseClassDescriptor(BCDA, TDA, _NumBases, 0, NegativeOne, 0, BaseAttributes, BCHDA),
    bcd_has_CHD_pointer(BitMask),
    (bitmask_check(BaseAttributes, BitMask) -> BCHDA is CHDA; true),

    %logtrace('Case: '), logtrace(BaseAttributes), logtrace(' BHCDA: '), logtrace(BCHDA),
    %logtrace(' TDA: '), logtrace(TDA), logtrace(' CHDA: '), logtrace(CHDA),
    %logtrace(' BCDA: '), logtraceln(BCDA),

    % Debugging.
    %logtrace('debug-rTTISelfRef('),
    %logtrace(TDA), logtrace(', '),
    %logtrace(COLA), logtrace(', '),
    %logtrace(CHDA), logtrace(', '),
    %logtrace(BCDA), logtrace(', '),
    %logtrace(VFTable), logtrace(', '),
    %logtrace('\''), logtrace(Name), logtrace('\''), logtraceln(').'),
    true.

:- table rTTINoBase/1 as opaque.
rTTINoBase(TDA) :-
    rTTITypeDescriptor(TDA, _TIVTable, _Name, _DName),
    rTTIBaseClassDescriptor(_BCDA, TDA, 0, _M, _P, _V, _BaseAttributes, _ECHDA).

:- table rTTIAncestorOf/2 as opaque.
rTTIAncestorOf(DerivedTDA, AncestorTDA) :-
    rTTICompleteObjectLocator(_Pointer, _COLA, DerivedTDA, CHDA, _Offset, _O2),
    rTTIClassHierarchyDescriptor(CHDA, _HierarchyAttributes, Bases),
    member(BCDA, Bases),
    rTTIBaseClassDescriptor(BCDA, AncestorTDA, _NumBases, _M, _P, _V, _BaseAttributes, _ECHDA),
    AncestorTDA \= DerivedTDA.

:- table rTTIInheritsIndirectlyFrom/2 as opaque.
rTTIInheritsIndirectlyFrom(DerivedTDA, AncestorTDA) :-
    rTTIAncestorOf(DerivedTDA, BaseTDA),
    rTTIAncestorOf(BaseTDA, AncestorTDA).

:- table rTTIInheritsDirectlyFrom/6 as opaque.
rTTIInheritsDirectlyFrom(DerivedTDA, AncestorTDA, Attributes, M, P, V) :-
    rTTICompleteObjectLocator(_Pointer, _COLA, DerivedTDA, CHDA, M, _O2),
    rTTIClassHierarchyDescriptor(CHDA, Attributes, Bases),
    member(BCDA, Bases),
    rTTIBaseClassDescriptor(BCDA, AncestorTDA, _NumBases, M, P, V, AttrValue, _ECHDA),
    % Check that virtual inheritance attribute flag is NOT set.
    bcd_virtual_base_of_contained_object(BitMask),
    not(bitmask_check(AttrValue, BitMask)),
    AncestorTDA \= DerivedTDA,

    % Cory has still not found a more obvious way to determine whether the inheritance is
    % direct using P, V, or other flags.  This approach raises questions about what happens in
    % cases where the base class is inherited both directly and indirectly.  Will this
    % algorithm miss the direct base if it's also a base of a base?
    not(rTTIInheritsIndirectlyFrom(DerivedTDA, AncestorTDA)),

    %logtrace('debug-rTTIInheritsDirectlyFrom('),
    %logtrace(DerivedTDA), logtrace(', '),
    %logtrace(AncestorTDA), logtrace(', '),
    %logtrace(Attributes), logtrace(', '),
    %logtrace(M), logtrace(', '),
    %logtrace(P), logtrace(', '),
    %logtrace(V), logtrace(', '),
    %logtrace(BCDA), logtraceln(').'),
    true.

:- table rTTIInheritsVirtuallyFrom/6 as opaque.
rTTIInheritsVirtuallyFrom(DerivedTDA, AncestorTDA, Attributes, M, P, V) :-
    rTTICompleteObjectLocator(_Pointer, _COLA, DerivedTDA, CHDA, M, _O2),
    rTTIClassHierarchyDescriptor(CHDA, Attributes, Bases),
    member(BCDA, Bases),
    rTTIBaseClassDescriptor(BCDA, AncestorTDA, _NumBases, M, P, V, AttrValue, _ECHDA),
    % Check that virtual inheritance attribute flag is set.
    bcd_virtual_base_of_contained_object(BitMask),
    bitmask_check(AttrValue, BitMask),
    AncestorTDA \= DerivedTDA,

    not(rTTIInheritsIndirectlyFrom(DerivedTDA, AncestorTDA)),

    % Is M always zero in virtual inheritance?

    % Debugging.
    %logtrace('debug-rTTIInheritsVirtuallyFrom('),
    %logtrace(DerivedTDA), logtrace(', '),
    %logtrace(AncestorTDA), logtrace(', '),
    %logtrace(Attributes), logtrace(', '),
    %logtrace(M), logtrace(', '),
    %logtrace(P), logtrace(', '),
    %logtrace(V), logtrace(', '),
    %logtrace(BCDA), logtraceln(').'),
    true.


:- table rTTIInheritsFrom/6 as opaque.
rTTIInheritsFrom(DerivedTDA, AncestorTDA, Attributes, M, P, V) :-
    (rTTIInheritsDirectlyFrom(DerivedTDA, AncestorTDA, Attributes, M, P, V);
     rTTIInheritsVirtuallyFrom(DerivedTDA, AncestorTDA, Attributes, M, P, V)).

% When RTTI is enabled, valid, and reports an inheritance relationship, this is a particularly
% strong assertion.  In particular, it represents a rare opportunity to make confident negative
% assertions -- this class is NOT derived from that class because the relationship wasn't in
% the RTTI data.  Because the conclusion is based entirely off of RTTI data, we cane compute
% these facts once at the beginning of the run, and be done with this rule for the rest of the
% analysis.  Additionally, this rule may be used efficiently in places where we would normally
% rely on sanity checking to detect contradictions because of the primacy of RTTI conclusions.
% The only catch is that the RTTI data only gives us VFTables, not class ids, so we'll have to
% call reasonPrimaryVFTableForClass(VFTable, Class) later to map these facts to get the correct
% class ids.
:- table rTTIDerivedClass/3 as opaque.
rTTIDerivedClass(DerivedVFTable, BaseVFTable, Offset) :-
    rTTIEnabled,
    rTTIValid,
    negative(1, NegativeOne),
    rTTIInheritsFrom(DerivedTDA, BaseTDA, _Attributes, Offset, NegativeOne, 0),
    rTTITDA2VFTable(DerivedTDA, DerivedVFTable),
    rTTITDA2VFTable(BaseTDA, BaseVFTable).

% --------------------------------------------------------------------------------------------
:- table reasonRTTIInformation/3 as incremental.

% This rule is only used in final.pl to obtain a class name now.  Perhaps it should be
% rewritten.
% PAPER: XXX
reasonRTTIInformation(VFTableAddress, Pointer, RTTIName) :-
    rTTICompleteObjectLocator(Pointer, _COLAddress, TDAddress, _CHDAddress, _O1, _O2),
    rTTITypeDescriptor(TDAddress, _VFTableCheck, RTTIName, _DName),
    VFTableAddress is Pointer + 4,
    factVFTable(VFTableAddress).

% ============================================================================================
% Validation
% ============================================================================================

% Base Class Descriptor (BCD) attribute flags.

% BCD_NOTVISIBLE
bcd_notvisible(0x01).

% BCD_AMBIGUOUS
bcd_ambiguous(0x02).

% BCD_PRIVORPROTINCOMPOBJ
bcd_private_or_protected_in_composite_object(0x04).

% BCD_PRIVORPROTBASE
bcd_private_or_protected_base(0x08).

% BCD_VBOFCONTOBJ
bcd_virtual_base_of_contained_object(0x10).

% BCD_NONPOLYMORPHIC
bcd_nonpolymorphic(0x20).

% BCD_HASPCHD
% BCD has an extra pointer trailing the structure to the ClassHierarchyDescriptor.
bcd_has_CHD_pointer(0x40).

% --------------------------------------------------------------------------------------------

rTTIInvalidBaseAttributes :-
    rTTIBaseClassDescriptor(_BCDA, _TDA, _NumBases, _M, _P, _V, Attributes, _CHDA),
    Attributes >= 0x80,
    Attributes < 0x0,
    logwarn('RTTI Information is invalid because BaseClassDescriptor Attributes = '),
    logwarnln(Attributes).

rTTIInvalidCOLOffset2 :-
    rTTICompleteObjectLocator(_Pointer, _COLA, _TDA, _CHDA, _Offset, Offset2),
    Offset2 \= 0x0,
    Offset2 \= 0x4,
    logwarn('RTTI Information is invalid because CompleteObjectLocator Offset2 = '),
    logwarnln(Offset2).

rTTIInvalidDirectInheritanceP :-
    Big is 0x7fffffff,
    NegativeOne is Big * 2 + 1,
    rTTIInheritsDirectlyFrom(_DerivedTDA, _AncestorTDA, _Attributes, _M, P, _V),
    P \= NegativeOne,
    logwarn('RTTI Information is invalid because InheritsDirectlyFrom P = '),
    logwarnln(P).

rTTIInvalidDirectInheritanceV :-
    rTTIInheritsDirectlyFrom(_DerivedTDA, _AncestorTDA, _Attributes, _M, _P, V),
    V \= 0x0,
    logwarn('RTTI Information is invalid because InheritsDirectlyFrom V = '),
    logwarnln(V).

rTTIInvalidHierarchyAttributes :-
    rTTIClassHierarchyDescriptor(_CHDA, HierarchyAttributes, _Bases),

    % Attributes 0x0 means a normal inheritance (non multiple/virtual)
    HierarchyAttributes \= 0x0,

    % Attributes 0x1 means multiple inheritance
    HierarchyAttributes \= 0x1,

    % Attributes 0x2 is not believed to be possible since it would imply virtual inheritance
    % without multiple inheritance.

    % Attributes 0x3 means multiple virtual inheritance
    HierarchyAttributes \= 0x3,
    logwarn('RTTI Information is invalid because HierarchyAttributes = '),
    logwarnln(HierarchyAttributes).

:- table rTTIShouldHaveSelfRef/1 as opaque.
rTTIShouldHaveSelfRef(TDA) :-
    rTTITypeDescriptor(TDA, _VFTableCheck, _RTTIName, _DName),
    rTTICompleteObjectLocator(_Pointer, _COLA, TDA, _CHDA, _O1, _O2).

:- table rTTIHasSelfRef/1 as opaque.
rTTIHasSelfRef(TDA) :-
    rTTISelfRef(TDA, _COLA, _CHDA, _BCDA, _VFTable, _Name).

:- table rTTIAllTypeDescriptors/1 as opaque.
rTTIAllTypeDescriptors(TDA) :-
    rTTITypeDescriptor(TDA, _VFTableCheck, _RTTIName, _DName).

rTTIAllTypeDescriptors(TDA) :-
    rTTICompleteObjectLocator(_Pointer, _Address, TDA, _CHDAddress, _Offset, _CDOffset).

rTTIAllTypeDescriptors(TDA) :-
    rTTIBaseClassDescriptor(_Address, TDA, _NumBases, _M, _P, _V, _Attr, _CHDA).

:- table rTTIHasTypeDescriptor/1 as opaque.
rTTIHasTypeDescriptor(TDA) :-
    rTTITypeDescriptor(TDA, _VFTableCheck, _RTTIName, _DName).

% Is the RTTI information internally consistent?
:- table rTTIValid/0 as opaque.
rTTIValid :-
    rTTIEnabled,
    reportRTTIInvalidity,
    not(rTTIInvalidBaseAttributes),
    not(rTTIInvalidCOLOffset2),
    not(rTTIInvalidDirectInheritanceP),
    not(rTTIInvalidDirectInheritanceV),
    setof(TDA, rTTIAllTypeDescriptors(TDA), TDASet1),
    maplist(rTTIHasTypeDescriptor, TDASet1),
    setof(TDA, rTTIShouldHaveSelfRef(TDA), TDASet2),
    maplist(rTTIHasSelfRef, TDASet2),
    true.

% ============================================================================================
% Reporting
% ============================================================================================

reportMissingSelfRef(TDA) :-
    rTTISelfRef(TDA, _COLA, _CHDA, _BCDA, _VFTable, _Name) -> true;
    (logwarn('RTTI Information is invalid because missing self-reference for TDA at address '), logwarnln(TDA)).

reportMissingTypeDescriptor(TDA) :-
    rTTITypeDescriptor(TDA, _VFTableCheck, _RTTIName, _DName) -> true;
    (logwarn('RTTI Information is invalid because no RTTITypeDescriptor at address '), logwarnln(TDA)).

reportRTTIInvalidity :-
    setof(TDA, rTTIAllTypeDescriptors(TDA), TDASet1),
    maplist(reportMissingTypeDescriptor, TDASet1),
    setof(TDA, rTTIShouldHaveSelfRef(TDA), TDASet2),
    maplist(reportMissingSelfRef, TDASet2),
    true.

reportNoBase((A)) :-
    write('rTTINoBaseName('),
    writeHex(A), write(', '),
    rTTIName(A, AName),
    write('\''), writeHex(AName), write('\''), writeln(').').
reportNoBase :-
    setof((A), rTTINoBase(A), Set),
    maplist(reportNoBase, Set).
reportNoBase :- true.

reportAncestorOf((D, A)) :-
    write('rTTIAncestorOfName('),
    writeHex(D), write(', '),
    writeHex(A), write(', '),
    rTTIName(D, DName),
    rTTIName(A, AName),
    write('\''), writeHex(DName), write('\''), write(', '),
    write('\''), writeHex(AName), write('\''), writeln(').').
reportAncestorOf :-
    setof((D, A), rTTIAncestorOf(D, A), Set),
    maplist(reportAncestorOf, Set).
reportAncestorOf :- true.

reportInheritsDirectlyFrom((D, A, H, M, P, V)) :-
    write('rTTIInheritsDirectlyFromName('),
    writeHex(D), write(', '),
    writeHex(A), write(', '),
    writeHex(H), write(', '),
    writeHex(M), write(', '),
    writeHex(P), write(', '),
    writeHex(V), write(', '),
    rTTIName(D, DName),
    rTTIName(A, AName),
    write('\''), writeHex(DName), write('\''), write(', '),
    write('\''), writeHex(AName), write('\''), writeln('). ').
reportInheritsDirectlyFrom :-
    setof((D, A, H, M, P, V), rTTIInheritsDirectlyFrom(D, A, H, M, P, V), Set),
    maplist(reportInheritsDirectlyFrom, Set).
reportInheritsDirectlyFrom :- true.

reportInheritsVirtuallyFrom((D, A, H, M, P, V)) :-
    write('rTTIInheritsVirtuallyFromName('),
    writeHex(D), write(', '),
    writeHex(A), write(', '),
    writeHex(H), write(', '),
    writeHex(M), write(', '),
    writeHex(P), write(', '),
    writeHex(V), write(', '),
    rTTIName(D, DName),
    rTTIName(A, AName),
    write('\''), writeHex(DName), write('\''), write(', '),
    write('\''), writeHex(AName), write('\''), writeln('). ').
reportInheritsVirtuallyFrom :-
    setof((D, A, H, M, P, V), rTTIInheritsVirtuallyFrom(D, A, H, M, P, V), Set),
    maplist(reportInheritsVirtuallyFrom, Set).
reportInheritsVirtuallyFrom :- true.


reportSelfRef((T, L, C, B, V, N)) :-
    write('rTTISelfRef('),
    writeHex(T), write(', '),
    writeHex(L), write(', '),
    writeHex(C), write(', '),
    writeHex(B), write(', '),
    writeHex(V), write(', '),
    write('\''), writeHex(N), write('\''), writeln('). ').
reportSelfRef :-
    setof((T, L, C, B, V, N), rTTISelfRef(T, L, C, B, V, N), Set),
    maplist(reportSelfRef, Set).
reportSelfRef :- true.

rTTISolve(X) :-
    loadInitialFacts(X),
    reportRTTIResults.

reportRTTIResults :-
    % Always enable RTTI before attempting to report on it.
    assert(rTTIEnabled),
    (rTTIValid -> writeln('RTTI was valid.') ; writeln('RTTI was invalid.')),
    reportNoBase,
    reportSelfRef,
    reportAncestorOf,
    reportInheritsDirectlyFrom,
    reportInheritsVirtuallyFrom,
    writeln('Report complete.').

/* Local Variables:   */
/* mode: prolog       */
/* fill-column:    95 */
/* comment-column: 0  */
/* End:               */
