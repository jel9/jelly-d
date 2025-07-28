module jelly.config;

import std.stdio;
import std.file : readText;
import std.exception : enforce;
import std.string : join, format;
import std.algorithm : map;
import std.uni : isWhite, isAlphaNum;
import std.ascii : isDigit;
import std.conv : to;
import std.variant : Algebraic;
import std.traits : hasUDA, getUDAs, FieldNameTuple, FieldTypeTuple;

/// Attribute to assign a default value to a field if the config key is missing.
struct Default(string val) { }

/// Alias for the configuration object, mapping keys to values.
alias Config = Value[string];

/// Algebraic type representing all possible value types in the configuration.
alias Variant = Algebraic!(string, double, Value[], Config);

/// Enum representing the kind of value stored.
enum ValueType : ubyte
{
    String,  /// A string value
    Number,  /// A numeric value (floating point)
    List,    /// An array of values
    Object   /// A nested configuration object (map)
}

/// Represents a configuration value with explicit type information.
struct Value
{
    Variant data;   /// The actual value data, type-erased using Algebraic
    ValueType type; /// The kind of value stored

    /// Converts the value to a string in configuration syntax.
    string toString() const
    {
        switch (type)
        {
        case ValueType.String:
            return `"` ~ data.get!string ~ `"`;
        case ValueType.Number:
            return to!string(data.get!double);
        case ValueType.List:
            {
                auto arr = data.get!(Value[]);
                return "[" ~ join(arr.map!(v => v.toString()), ", ") ~ "]";
            }
        case ValueType.Object:
            {
                auto m = data.get!Config;
                string[] items;
                foreach (kv; m.byKeyValue)
                    items ~= kv.key ~ " = " ~ kv.value.toString();
                return "{" ~ join(items, ", ") ~ "}";
            }
        default:
            assert(0, "Unreachable ValueType");
        }
    }
}

/// Parses a configuration string into a Config object.
/// Supports nested objects, lists, strings, and numbers.
struct Parser
{
    private string src;
    private size_t pos;

    /// Constructs a parser for the given configuration text.
    this(string text)
    {
        src = text;
        pos = 0;
    }

    /// Parses the entire configuration text into a Config object.
    Config parse()
    {
        Config root;
        while (!eof)
        {
            skip();
            if (eof || peek == '}')
                break;

            auto key = parseKey();
            skip();

            Value val;
            if (peek == '{')
            {
                next();
                skip();
                auto obj = parse();
                enforce(peek == '}', "Unmatched '{' in object literal");
                next();
                val = Value(Variant(obj), ValueType.Object);
            }
            else
            {
                enforce(next() == '=', "Expected '=' after " ~ key);
                skip();
                val = parseValue();
            }
            root[key] = val;
        }
        return root;
    }

    /// Parses a value: string, list, object, or number.
    private Value parseValue()
    {
        enforce(!eof, "Unexpected EOF");
        char c = peek;
        if (c == '"')
            return parseString();
        if (c == '[')
            return parseList();
        if (c == '{')
        {
            next();
            skip();
            auto obj = parse();
            enforce(peek == '}', "Unmatched '{' in inline object");
            next();
            return Value(Variant(obj), ValueType.Object);
        }
        if (isDigit(c) || c == '-')
            return parseNumber();

        assert(0, "Invalid value start: '" ~ c ~ "' at pos " ~ to!string(pos));
    }

    /// Parses a string literal.
    private Value parseString()
    {
        next();
        size_t start = pos;
        while (!eof && peek != '"')
            next();
        enforce(!eof, "Unterminated string literal");
        auto s = src[start .. pos];
        next();
        return Value(Variant(s), ValueType.String);
    }

    /// Parses a numeric literal.
    private Value parseNumber()
    {
        size_t start = pos;
        if (peek == '-')
            next();
        while (!eof && (isDigit(peek) || peek == '.'))
            next();
        double n = src[start .. pos].to!double;
        return Value(Variant(n), ValueType.Number);
    }

    /// Parses a list [v, v, ...].
    private Value parseList()
    {
        next();
        skip();
        Value[] arr;
        while (!eof && peek != ']')
        {
            arr ~= parseValue();
            skip();
            if (peek == ',')
            {
                next();
                skip();
            }
        }
        enforce(peek == ']', "Unterminated list literal");
        next();
        return Value(Variant(arr), ValueType.List);
    }

    /// Parses an identifier key.
    private string parseKey()
    {
        size_t start = pos;
        enforce(!eof, "EOF in key");
        while (!eof && (isAlphaNum(peek) || peek == '_'))
            next();
        enforce(pos > start, "Empty key at pos " ~ to!string(pos));
        return src[start .. pos];
    }

    private void skip()
    {
        while (!eof)
        {
            if (isWhite(peek)) { next(); continue; }
            if (peek == '#')
            {
                next();
                while (!eof && peek != '\n') next();
                continue;
            }
            break;
        }
    }

    @property private char peek() const { return eof ? '\0' : src[pos]; }
    private char next() { return src[pos++]; }
    @property private bool eof() const { return pos >= src.length; }
}

/// Compile-time configuration parser (CTFE).
enum ctfeParse(string text) = Parser(text).parse();

import std.traits;

/// Template to generate typed accessor methods for fields marked with `@ConfigKey` or `@Default`.
template GenerateAccessors(T)
{
    static foreach (idx, name; FieldNameTuple!T)
    {
        alias FT = FieldTypeTuple!T[idx];
        static if (hasUDA!(T, name, ConfigKey))
        {
            enum key = getUDAs!(T, name, ConfigKey)[0].key;
            mixin(templateAccessor!(T.stringof, name, FT.stringof, key));
        }
        else static if (hasUDA!(T, name, Default))
        {
            enum def = getUDAs!(T, name, Default)[0].val;
            enum key = name;
            mixin(templateAccessorWithDefault!(T.stringof, name, FT.stringof, key, def));
        }
    }
}

private string templateAccessor(string structName, string fieldName, string fieldType, string key)
{
    immutable tpl = q{
    /// Returns the value of the configuration key "%s".
    /// Throws if the key does not exist.
    %s %s() const {
        auto cfg = this._cfg;
        enforce(cfg.exists("%s"), "Missing key '%s'");
        auto val = cfg["%s"];
        return cast(%s) val.data.get!(%s);
    }
    };
    return tpl.format(fieldType, structName, fieldName, key, key, key, fieldType, fieldType);
}

private string templateAccessorWithDefault(string structName, string fieldName, string fieldType, string key, string def)
{
    immutable tpl = q{
    /// Returns the value of the configuration key "%s", or a default if missing.
    %s %s() const {
        auto cfg = this._cfg;
        return cfg.exists("%s")
            ? cast(%s) cfg["%s"].data.get!(%s)
            : cast(%s)"%s";
    }
    };
    return tpl.format(fieldType, structName, fieldName, key, fieldType, key, fieldType, fieldType, def);
}

unittest {
    string cfgText = `
        name = "Jelly"
        enabled = 1
        feature_on = 0
    `;
    auto parser = Parser(cfgText);
    Config cfg = parser.parse();
    assert(cfg["enabled"].data.get!double == 1);
    assert(cfg["feature_on"].data.get!double == 0);
}

unittest {
    string cfgText = `
        name = "Jelly"
        data = {
            is_cool = 1
        }
    `;
    auto parser = Parser(cfgText);
    Config cfg = parser.parse();
    assert(cfg["data"].data.get!Config["is_cool"].data.get!double == 1);
}
