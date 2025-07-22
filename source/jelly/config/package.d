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
    private string src;  /// Source configuration text
    private size_t pos;  /// Current position in the source text

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
            if (eof)
                break;

            string key = parseKey();
            skip();

            if (peek == '{')
            {
                next();
                skip();
                auto obj = parse();
                enforce(peek == '}', "Unmatched '{' in " ~ key);
                next();
                root[key] = Value(Variant(obj), ValueType.Object);
            }
            else
            {
                enforce(next() == '=', "Expected '=' after " ~ key);
                skip();
                auto v = parseValue();
                root[key] = v;
            }
        }
        return root;
    }

    /// Parses a value from the configuration text.
    /// Recognizes strings, lists, objects, and numbers.
    private Value parseValue()
    {
        enforce(!eof, "Unexpected EOF");
        auto c = peek;

        if (c == '"')
            return parseString();
        if (c == '[')
            return parseList();
        if (c == '{')
        {
            next();
            skip();
            auto obj = parse();
            enforce(peek == '}', "Unmatched '{'");
            next();
            return Value(Variant(obj), ValueType.Object);
        }
        if (isDigit(c) || c == '-')
            return parseNumber();

        assert(0, "Invalid value start: '" ~ c ~ "' at pos " ~ to!string(pos));
    }

    /// Parses a string literal value.
    private Value parseString()
    {
        next(); // skip opening quote
        size_t start = pos;
        while (!eof && peek != '"')
            next();
        enforce(!eof, "Unterminated string literal");
        auto s = src[start .. pos];
        next(); // skip closing quote
        return Value(Variant(s), ValueType.String);
    }

    /// Parses a numeric value (integer or floating point).
    private Value parseNumber()
    {
        size_t start = pos;
        if (peek == '-')
            next();
        while (!eof && (isDigit(peek) || peek == '.'))
            next();
        double num = src[start .. pos].to!double;
        return Value(Variant(num), ValueType.Number);
    }

    /// Parses a list of values (comma-separated, in square brackets).
    private Value parseList()
    {
        next(); // skip '['
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
        enforce(peek == ']', "Unterminated list");
        next(); // skip ']'
        return Value(Variant(arr), ValueType.List);
    }

    /// Parses a key (identifier) for an object entry.
    private string parseKey()
    {
        size_t start = pos;
        enforce(!eof, "EOF in key");
        while (!eof && (isAlphaNum(peek) || peek == '_'))
            next();
        enforce(pos > start, "Empty key at pos " ~ to!string(pos));
        return src[start .. pos];
    }

    /// Skips whitespace and comments in the configuration text.
    private void skip()
    {
        while (!eof)
        {
            if (isWhite(peek))
            {
                next();
                continue;
            }
            if (peek == '#')
            {
                next();
                while (!eof && peek != '\n')
                    next();
                continue;
            }
            break;
        }
    }

    /// Returns the current character, or '\0' if at end of file.
    @property private char peek() const
    {
        return eof ? '\0' : src[pos];
    }

    /// Advances to the next character and returns the current one.
    private char next()
    {
        return src[pos++];
    }

    /// Returns true if parsing has reached the end of the source text.
    @property private bool eof() const
    {
        return pos >= src.length;
    }
}

/// Compile-time configuration parser (CTFE).
/// Usage: enum parsedConfig = ctfeParse!"key = 123";
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
            mixin(templateAccessorWithDefault!(T.stringof, name, FT.stringof, key, def));
        }
    }
}

/// Generates a getter accessor for the given config key.
/// Throws if the key is missing.
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

/// Generates a getter accessor with a default value for the given config key.
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