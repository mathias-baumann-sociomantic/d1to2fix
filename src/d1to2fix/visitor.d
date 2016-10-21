/******************************************************************************

    Custom dparse visitor class iterates resulting AST and creates
    mappings between language constructs that need to be converted and token
    indexes in the original lexed array.

    Copyright: Copyright (c) 2016 Sociomantic Labs. All rights reserved

    License: Boost Software License Version 1.0 (see LICENSE for details)

******************************************************************************/

module d1to2fix.visitor;

import dparse.parser;
import dparse.lexer;
import dparse.ast;

/**
    Aggregates all necessary data generated by TokenMappingVisitor that will
    be used from other modules.
 **/
public struct TokenMappings
{
    import util.intervals;

    /// Gives the index at which to prepend 'scope' so that '[.]Type2 delegate'
    /// function parameter becomes 'scope Type2 delegate'. Also tracks delegate
    /// declarations inside aliases.
    OrderedIntervals scope_delegates;

    /// Tracks index intervals of struct/union bodies for converting "this"
    /// keyword.
    OrderedIntervals value_aggregates;
}

/**
    Custom ASTVisitor

    Combines generation of several unrelated mappings at once for performance
    reasons (to avoid multiple redundant visiting of same AST).
 **/
public final class TokenMappingVisitor : ASTVisitor
{
    private
    {
        const Token[] tokens;
        string fileName;

        TokenMappings token_mappings;
    }

    public this (const Token[] toks, string file)
    {
        this.tokens = toks;
        this.fileName = file;
    }

    public auto foundTokenMappings ( )
    {
        return this.token_mappings;
    }

    // Introduces base class `visit`
    public alias visit = super.visit;

    /*
        `visit` overrides related to struct/union body tracking
     */

    public override void visit (const StructDeclaration node)
    {
        if (node.structBody !is null)
        {
            this.token_mappings.value_aggregates.add(
                node.structBody.startLocation,
                node.structBody.endLocation
            );
        }
        super.visit(node);
    }

    public override void visit (const UnionDeclaration node)
    {
        if (node.structBody !is null)
        {
            this.token_mappings.value_aggregates.add(
                node.structBody.startLocation,
                node.structBody.endLocation
            );
        }

        super.visit(node);
    }

    private static size_t ctorEndLocation (Node) (Node node)
    {
        if (node.functionBody is null)
            return node.location + 2;
        if (node.functionBody.blockStatement !is null)
            return node.functionBody.blockStatement.endLocation;
        assert (node.functionBody.bodyStatement.blockStatement !is null);
        return node.functionBody.bodyStatement.blockStatement.endLocation;
    }

    public override void visit (const StaticConstructor node)
    {
        // don't convert static constructors in structs
        // applies to both body and declaration
        this.token_mappings.value_aggregates.remove(node.location, ctorEndLocation(node));
    }

    public override void visit (const StaticDestructor node)
    {
        // don't convert static destructors in structs
        // applies to both body and declaration
        this.token_mappings.value_aggregates.remove(node.location, ctorEndLocation(node));
    }

    public override void visit (const ClassDeclaration node)
    {
        if (node.structBody !is null)
        {
            this.token_mappings.value_aggregates.remove(
                node.structBody.startLocation,
                node.structBody.endLocation
            );
        }
        super.visit(node);
    }

    /*
        `visit` overrides related to delegate tracking
     */

    public override void visit (const FunctionDeclaration node)
    {
        // It isn't possible to visit all delegate declarations
        // directly thus one need to start with functions and
        // navigate from the manually

        if (node.parameters)
        {
            foreach (param; node.parameters.parameters)
            {
                if (param.type)
                {
                    this.checkDelegate(param.type, param.name);
                }
            }
            super.visit(node);
        }
    }

    public override void visit (const Constructor node)
    {
        // Mimic `FunctionDeclaration`.

        if (node.parameters)
        {
            foreach (param; node.parameters.parameters)
            {
                if (param.type)
                {
                    this.checkDelegate(param.type, param.name);
                }
            }
            super.visit(node);
        }
    }

    /**
        If the node has a delegate, add the index at which to place
        the `scope` to `this.token_mappings.scope_delegates`

        Params:
            type = parameter type
            token = parameter name token
    **/
    private void checkDelegate (const Type type, Token token)
    {
        assert(type !is null, "Null type passed to checkDelegate");

        // Check "plain" delegates.
        //
        // The return type is in 'type2', and the delegate information in
        // typesuffix. The conditions below are simplified, as we're in D1
        // and thus don't have to care about inout, const, immutable or shared.
        if (type.typeSuffixes.length
            && type.typeSuffixes[0].delegateOrFunction == tok!"delegate")
        {
            // Found a delegate, now we need the index at which
            // to place the 'scope'...
            this.token_mappings.scope_delegates.add(this.calculateIndex(type));
        }
        // Check aliased delegate.
        //
        // Does global lookup among known aliases using unqualified parameter type
        // name which may result in false positivies unless all delegate aliases
        // have unique names.
        else if (type.type2.symbol !is null)
        {
            import std.array;
            import std.algorithm : map;

            // use unqualified symbol name for lookup - our delegate names are
            // usually uniquely named and dsymbol is not well-suited for task
            // of finding fully qualified names

            auto name = type.type2.symbol.identifierOrTemplateChain
                .identifiersOrTemplateInstances[$-1].identifier.text;

            import d1to2fix.symbolsearch;
            import dsymbol.symbol;

            auto sym = delegateAliasSearch(name);

            if (sym)
                this.token_mappings.scope_delegates.add(this.calculateIndex(type));
        }
    }

    /**
        Params:
            type = parameter type to inject `scope` before

        Returns:
            Index in token sequence where `scope` keyword needs to be inserted
            so that it will be placed before delegate parameter declaration.
    **/
    private size_t calculateIndex ( const Type type )
    {
        auto t2 = type.type2;
        // If it's a builtin type (type is irrelevant)
        if (t2.builtinType != 0)
        {
            auto idx = getTokIndex(type.typeSuffixes[0]
                                   .delegateOrFunction.index);
            this.assert_(isBasicType(this.tokens[idx - 1].type),
                         "Expected a builtin type", this.tokens[idx -1]);

            return this.tokens[idx - 1].index;
        }
        else if (t2.symbol
                 && t2.symbol.identifierOrTemplateChain
                 && t2.symbol.identifierOrTemplateChain
                    .identifiersOrTemplateInstances.length)
        {
            // It's either an identifier or a template instance
            auto ioti = t2.symbol.identifierOrTemplateChain
                .identifiersOrTemplateInstances[0];
            // If there is, it CAN have a leading dot...
            ubyte decr = t2.symbol.dot ? 1 : 0;
            // Definitely an identifier
            if (ioti.identifier.type != 0)
                return ioti.identifier.index - decr;
            else
                return ioti.templateInstance.identifier.index - decr;
        }
        else
            return 0;
    }

    /**
        Params:
            globalIndex = index in the parsed file

        Returns:
            Index into the array of parser tokens that matches
            globalIndex
    **/
    private size_t getTokIndex (size_t globalIndex)
    {
        foreach (idx, t; this.tokens)
        {
            if (t.index == globalIndex)
                return idx;
        }
        assert(0);
    }

    /*
        Provide informative error message
     */
    private void assert_ (bool cond, string msg, Token tok)
    {
        if (!cond)
        {
            import std.stdio : stderr;
            stderr.writefln("d1to2fix error: {} ({}:{},{})",
                            msg, this.fileName, tok.line, tok.column);
            assert(0);
        }
    }
}
