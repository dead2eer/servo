/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// This file is a Mako template: http://www.makotemplates.org/

pub use std::ascii::StrAsciiExt;
use serialize::{Encodable, Encoder};

pub use servo_util::url::parse_url;
use sync::Arc;
pub use url::Url;

pub use cssparser::*;
pub use cssparser::ast::*;

use errors::{ErrorLoggerIterator, log_css_error};
pub use parsing_utils::*;
pub use self::common_types::*;
use selector_matching::MatchedProperty;


pub use self::property_bit_field::PropertyBitField;
pub mod common_types;


<%!

import re

def to_rust_ident(name):
    name = name.replace("-", "_")
    if name in ["static", "super", "box"]:  # Rust keywords
        name += "_"
    return name

class Longhand(object):
    def __init__(self, name, derived_from=None):
        self.name = name
        self.ident = to_rust_ident(name)
        self.camel_case, _ = re.subn(
            "_([a-z])",
            lambda m: m.group(1).upper(),
            self.ident.strip("_").capitalize())
        self.style_struct = THIS_STYLE_STRUCT
        if derived_from is None:
            self.derived_from = None
        else:
            self.derived_from = [ to_rust_ident(name) for name in derived_from ]

class Shorthand(object):
    def __init__(self, name, sub_properties):
        self.name = name
        self.ident = to_rust_ident(name)
        self.sub_properties = [LONGHANDS_BY_NAME[s] for s in sub_properties]

class StyleStruct(object):
    def __init__(self, name, inherited):
        self.name = name
        self.ident = to_rust_ident(name.lower())
        self.longhands = []
        self.inherited = inherited

STYLE_STRUCTS = []
THIS_STYLE_STRUCT = None
LONGHANDS = []
LONGHANDS_BY_NAME = {}
DERIVED_LONGHANDS = {}
SHORTHANDS = []

def new_style_struct(name, is_inherited):
    global THIS_STYLE_STRUCT

    style_struct = StyleStruct(name, is_inherited)
    STYLE_STRUCTS.append(style_struct)
    THIS_STYLE_STRUCT = style_struct
    return ""

def switch_to_style_struct(name):
    global THIS_STYLE_STRUCT

    for style_struct in STYLE_STRUCTS:
        if style_struct.name == name:
            THIS_STYLE_STRUCT = style_struct
            return ""
    fail()
%>

pub mod longhands {
    pub use super::*;
    pub use std;

    pub fn computed_as_specified<T>(value: T, _context: &computed::Context) -> T {
        value
    }

    <%def name="raw_longhand(name, no_super=False, derived_from=None)">
    <%
        if derived_from is not None:
            derived_from = derived_from.split()

        property = Longhand(name, derived_from=derived_from)
        THIS_STYLE_STRUCT.longhands.append(property)
        LONGHANDS.append(property)
        LONGHANDS_BY_NAME[name] = property

        if derived_from is not None:
            for name in derived_from:
                DERIVED_LONGHANDS.setdefault(name, []).append(property)
    %>
        pub mod ${property.ident} {
            % if not no_super:
                use super::*;
            % endif
            pub use self::computed_value::*;
            ${caller.body()}
            % if derived_from is None:
                pub fn parse_declared(input: &[ComponentValue], base_url: &Url)
                                   -> Option<DeclaredValue<SpecifiedValue>> {
                    match CSSWideKeyword::parse(input) {
                        Some(Some(keyword)) => Some(CSSWideKeyword(keyword)),
                        Some(None) => Some(CSSWideKeyword(${
                            "Inherit" if THIS_STYLE_STRUCT.inherited else "Initial"})),
                        None => parse_specified(input, base_url),
                    }
                }
            % endif
        }
    </%def>

    <%def name="longhand(name, no_super=False, derived_from=None)">
        <%self:raw_longhand name="${name}" derived_from="${derived_from}">
            ${caller.body()}
            % if derived_from is None:
                pub fn parse_specified(_input: &[ComponentValue], _base_url: &Url)
                                   -> Option<DeclaredValue<SpecifiedValue>> {
                    parse(_input, _base_url).map(super::SpecifiedValue)
                }
            % endif
        </%self:raw_longhand>
    </%def>

    <%def name="single_component_value(name, derived_from=None)">
        <%self:longhand name="${name}" derived_from="${derived_from}">
            ${caller.body()}
            pub fn parse(input: &[ComponentValue], base_url: &Url) -> Option<SpecifiedValue> {
                one_component_value(input).and_then(|c| from_component_value(c, base_url))
            }
        </%self:longhand>
    </%def>

    <%def name="single_keyword_computed(name, values)">
        <%self:single_component_value name="${name}">
            ${caller.body()}
            pub mod computed_value {
                #[allow(non_camel_case_types)]
                #[deriving(Eq, Clone, FromPrimitive)]
                pub enum T {
                    % for value in values.split():
                        ${to_rust_ident(value)},
                    % endfor
                }
            }
            pub type SpecifiedValue = computed_value::T;
            #[inline] pub fn get_initial_value() -> computed_value::T {
                ${to_rust_ident(values.split()[0])}
            }
            pub fn from_component_value(v: &ComponentValue, _base_url: &Url)
                                        -> Option<SpecifiedValue> {
                get_ident_lower(v).and_then(|keyword| {
                    match keyword.as_slice() {
                        % for value in values.split():
                            "${value}" => Some(${to_rust_ident(value)}),
                        % endfor
                        _ => None,
                    }
                })
            }
        </%self:single_component_value>
    </%def>

    <%def name="single_keyword(name, values)">
        <%self:single_keyword_computed name="${name}"
                                       values="${values}">
            // The computed value is the same as the specified value.
            pub use to_computed_value = super::computed_as_specified;
        </%self:single_keyword_computed>
    </%def>

    <%def name="predefined_type(name, type, initial_value, parse_method='parse')">
        <%self:single_component_value name="${name}">
            pub use to_computed_value = super::super::common_types::computed::compute_${type};
            pub type SpecifiedValue = specified::${type};
            pub mod computed_value {
                pub type T = super::super::computed::${type};
            }
            #[inline] pub fn get_initial_value() -> computed_value::T { ${initial_value} }
            #[inline] pub fn from_component_value(v: &ComponentValue, _base_url: &Url)
                                                  -> Option<SpecifiedValue> {
                specified::${type}::${parse_method}(v)
            }
        </%self:single_component_value>
    </%def>


    // CSS 2.1, Section 8 - Box model

    ${new_style_struct("Margin", is_inherited=False)}

    % for side in ["top", "right", "bottom", "left"]:
        ${predefined_type("margin-" + side, "LengthOrPercentageOrAuto",
                          "computed::LPA_Length(Au(0))")}
    % endfor

    ${new_style_struct("Padding", is_inherited=False)}

    % for side in ["top", "right", "bottom", "left"]:
        ${predefined_type("padding-" + side, "LengthOrPercentage",
                          "computed::LP_Length(Au(0))",
                          "parse_non_negative")}
    % endfor

    ${new_style_struct("Border", is_inherited=False)}

    % for side in ["top", "right", "bottom", "left"]:
        ${predefined_type("border-%s-color" % side, "CSSColor", "CurrentColor")}
    % endfor

    ${single_keyword("border-top-style", values="none solid double dotted dashed hidden groove ridge inset outset")}

    % for side in ["right", "bottom", "left"]:
        <%self:longhand name="border-${side}-style", no_super="True">
            pub use super::border_top_style::{get_initial_value, parse, to_computed_value};
            pub type SpecifiedValue = super::border_top_style::SpecifiedValue;
            pub mod computed_value {
                pub type T = super::super::border_top_style::computed_value::T;
            }
        </%self:longhand>
    % endfor

    pub fn parse_border_width(component_value: &ComponentValue, _base_url: &Url)
                              -> Option<specified::Length> {
        match component_value {
            &Ident(ref value) => {
                match value.to_owned().to_ascii_lower().as_slice() {
                    "thin" => Some(specified::Length::from_px(1.)),
                    "medium" => Some(specified::Length::from_px(3.)),
                    "thick" => Some(specified::Length::from_px(5.)),
                    _ => None
                }
            },
            _ => specified::Length::parse_non_negative(component_value)
        }
    }
    % for side in ["top", "right", "bottom", "left"]:
        <%self:longhand name="border-${side}-width">
            pub type SpecifiedValue = specified::Length;
            pub mod computed_value {
                use super::super::Au;
                pub type T = Au;
            }
            #[inline] pub fn get_initial_value() -> computed_value::T {
                Au::from_px(3)  // medium
            }
            pub fn parse(input: &[ComponentValue], base_url: &Url) -> Option<SpecifiedValue> {
                one_component_value(input).and_then(|c| parse_border_width(c, base_url))
            }
            #[inline]
            pub fn to_computed_value(value: SpecifiedValue, context: &computed::Context)
                                  -> computed_value::T {
                if !context.border_${side}_present {
                    Au(0)
                } else {
                    computed::compute_Au(value, context)
                }
            }
        </%self:longhand>
    % endfor

    ${new_style_struct("PositionOffsets", is_inherited=False)}

    % for side in ["top", "right", "bottom", "left"]:
        ${predefined_type(side, "LengthOrPercentageOrAuto",
                          "computed::LPA_Auto")}
    % endfor

    // CSS 2.1, Section 9 - Visual formatting model

    ${new_style_struct("Box", is_inherited=False)}

    // TODO: don't parse values we don't support
    <%self:single_keyword_computed name="display"
            values="inline block inline-block
            table inline-table table-row-group table-header-group table-footer-group
            table-row table-column-group table-column table-cell table-caption
            list-item
            none">
        #[inline]
        pub fn to_computed_value(value: SpecifiedValue, context: &computed::Context)
                              -> computed_value::T {
//            if context.is_root_element && value == list_item {
//                return block
//            }
            if context.positioned || context.floated || context.is_root_element {
                match value {
                    inline_table => table,
                    inline | inline_block
                    | table_row_group | table_column | table_column_group
                    | table_header_group | table_footer_group | table_row
                    | table_cell | table_caption
                    => block,
                    _ => value,
                }
            } else {
                value
            }
        }
    </%self:single_keyword_computed>

    ${single_keyword("position", "static absolute relative fixed")}
    ${single_keyword("float", "none left right")}
    ${single_keyword("clear", "none left right both")}

    ${new_style_struct("InheritedBox", is_inherited=True)}

    ${single_keyword("direction", "ltr rtl")}

    // CSS 2.1, Section 10 - Visual formatting model details

    ${switch_to_style_struct("Box")}

    ${predefined_type("width", "LengthOrPercentageOrAuto",
                      "computed::LPA_Auto",
                      "parse_non_negative")}
    <%self:single_component_value name="height">
        pub type SpecifiedValue = specified::LengthOrPercentageOrAuto;
        pub mod computed_value {
            pub type T = super::super::computed::LengthOrPercentageOrAuto;
        }
        #[inline]
        pub fn get_initial_value() -> computed_value::T { computed::LPA_Auto }
        #[inline]
        pub fn from_component_value(v: &ComponentValue, _base_url: &Url)
                                              -> Option<SpecifiedValue> {
            specified::LengthOrPercentageOrAuto::parse_non_negative(v)
        }
        pub fn to_computed_value(value: SpecifiedValue, context: &computed::Context)
                              -> computed_value::T {
            match (value, context.inherited_height) {
                (specified::LPA_Percentage(_), computed::LPA_Auto)
                if !context.is_root_element && !context.positioned => {
                    computed::LPA_Auto
                },
                _ => computed::compute_LengthOrPercentageOrAuto(value, context)
            }
        }
    </%self:single_component_value>

    ${predefined_type("min-width", "LengthOrPercentage",
                      "computed::LP_Length(Au(0))",
                      "parse_non_negative")}
    ${predefined_type("max-width", "LengthOrPercentageOrNone",
                      "computed::LPN_None",
                      "parse_non_negative")}

    ${predefined_type("min-height", "LengthOrPercentage",
                      "computed::LP_Length(Au(0))",
                      "parse_non_negative")}
    ${predefined_type("max-height", "LengthOrPercentageOrNone",
                      "computed::LPN_None",
                      "parse_non_negative")}

    ${switch_to_style_struct("InheritedBox")}

    <%self:single_component_value name="line-height">
        #[deriving(Clone)]
        pub enum SpecifiedValue {
            SpecifiedNormal,
            SpecifiedLength(specified::Length),
            SpecifiedNumber(CSSFloat),
            // percentage are the same as em.
        }
        /// normal | <number> | <length> | <percentage>
        pub fn from_component_value(input: &ComponentValue, _base_url: &Url)
                                    -> Option<SpecifiedValue> {
            match input {
                &ast::Number(ref value) if value.value >= 0.
                => Some(SpecifiedNumber(value.value)),
                &ast::Percentage(ref value) if value.value >= 0.
                => Some(SpecifiedLength(specified::Em(value.value / 100.))),
                &Dimension(ref value, ref unit) if value.value >= 0.
                => specified::Length::parse_dimension(value.value, unit.as_slice())
                    .map(SpecifiedLength),
                &Ident(ref value) if value.to_owned().eq_ignore_ascii_case("normal")
                => Some(SpecifiedNormal),
                _ => None,
            }
        }
        pub mod computed_value {
            use super::super::{Au, CSSFloat};
            #[deriving(Eq, Clone)]
            pub enum T {
                Normal,
                Length(Au),
                Number(CSSFloat),
            }
        }
        #[inline]
        pub fn get_initial_value() -> computed_value::T { Normal }
        #[inline]
        pub fn to_computed_value(value: SpecifiedValue, context: &computed::Context)
                              -> computed_value::T {
            match value {
                SpecifiedNormal => Normal,
                SpecifiedLength(value) => Length(computed::compute_Au(value, context)),
                SpecifiedNumber(value) => Number(value),
            }
        }
    </%self:single_component_value>

    <%self:longhand name="-servo-minimum-line-height" derived_from="line-height">
        use super::Au;
        use super::super::common_types::DEFAULT_LINE_HEIGHT;
        use super::super::longhands::display;
        use super::super::longhands::line_height;

        pub use to_computed_value = super::computed_as_specified;

        pub type SpecifiedValue = line_height::SpecifiedValue;

        pub mod computed_value {
            pub type T = super::super::Au;
        }

        #[inline]
        pub fn get_initial_value() -> computed_value::T {
            Au(0)
        }

        #[inline]
        pub fn derive_from_line_height(value: line_height::computed_value::T,
                                       context: &computed::Context)
                                       -> Au {
            if context.display != display::computed_value::inline {
                match value {
                    line_height::Normal => context.font_size.scale_by(DEFAULT_LINE_HEIGHT),
                    line_height::Number(percentage) => context.font_size.scale_by(percentage),
                    line_height::Length(length) => length,
                }
            } else {
                context.inherited_minimum_line_height
            }
        }
    </%self:longhand>

    ${switch_to_style_struct("Box")}

    <%self:single_component_value name="vertical-align">
        <% vertical_align_keywords = (
            "baseline sub super top text-top middle bottom text-bottom".split()) %>
        #[allow(non_camel_case_types)]
        #[deriving(Clone)]
        pub enum SpecifiedValue {
            % for keyword in vertical_align_keywords:
                Specified_${to_rust_ident(keyword)},
            % endfor
            SpecifiedLengthOrPercentage(specified::LengthOrPercentage),
        }
        /// baseline | sub | super | top | text-top | middle | bottom | text-bottom
        /// | <percentage> | <length>
        pub fn from_component_value(input: &ComponentValue, _base_url: &Url)
                                    -> Option<SpecifiedValue> {
            match input {
                &Ident(ref value) => {
                    match value.to_owned().to_ascii_lower().as_slice() {
                        % for keyword in vertical_align_keywords:
                        "${keyword}" => Some(Specified_${to_rust_ident(keyword)}),
                        % endfor
                        _ => None,
                    }
                },
                _ => specified::LengthOrPercentage::parse_non_negative(input)
                     .map(SpecifiedLengthOrPercentage)
            }
        }
        pub mod computed_value {
            use super::super::{Au, CSSFloat};
            #[allow(non_camel_case_types)]
            #[deriving(Eq, Clone)]
            pub enum T {
                % for keyword in vertical_align_keywords:
                    ${to_rust_ident(keyword)},
                % endfor
                Length(Au),
                Percentage(CSSFloat),
            }
        }
        #[inline]
        pub fn get_initial_value() -> computed_value::T { baseline }
        #[inline]
        pub fn to_computed_value(value: SpecifiedValue, context: &computed::Context)
                              -> computed_value::T {
            match value {
                % for keyword in vertical_align_keywords:
                    Specified_${to_rust_ident(keyword)} => ${to_rust_ident(keyword)},
                % endfor
                SpecifiedLengthOrPercentage(value)
                => match computed::compute_LengthOrPercentage(value, context) {
                    computed::LP_Length(value) => Length(value),
                    computed::LP_Percentage(value) => Percentage(value)
                }
            }
        }
    </%self:single_component_value>


    // CSS 2.1, Section 11 - Visual effects
    ${single_keyword("overflow", "visible hidden")} // TODO: scroll auto

    ${switch_to_style_struct("InheritedBox")}

    // TODO: collapse. Well, do tables first.
    ${single_keyword("visibility", "visible hidden")}

    // CSS 2.1, Section 12 - Generated content, automatic numbering, and lists

    ${switch_to_style_struct("Box")}

    <%self:longhand name="content">
            pub use to_computed_value = super::computed_as_specified;
            pub mod computed_value {
                #[deriving(Eq, Clone)]
                pub enum Content {
                    StringContent(~str),
                }
                #[allow(non_camel_case_types)]
                #[deriving(Eq, Clone)]
                pub enum T {
                    normal,
                    none,
                    Content(Vec<Content>),
                }
            }
            pub type SpecifiedValue = computed_value::T;
            #[inline] pub fn get_initial_value() -> computed_value::T  { normal }

            // normal | none | [ <string> ]+
            // TODO: <uri>, <counter>, attr(<identifier>), open-quote, close-quote, no-open-quote, no-close-quote
            pub fn parse(input: &[ComponentValue], _base_url: &Url) -> Option<SpecifiedValue> {
                match one_component_value(input) {
                    Some(&Ident(ref keyword)) => {
                        match keyword.to_owned().to_ascii_lower().as_slice() {
                            "normal" => return Some(normal),
                            "none" => return Some(none),
                            _ => ()
                        }
                    },
                    _ => ()
                }
                let mut content = vec!();
                for component_value in input.skip_whitespace() {
                    match component_value {
                        &String(ref value)
                        => content.push(StringContent(value.to_owned())),
                        _ => return None  // invalid/unsupported value
                    }
                }
                Some(Content(content))
            }
    </%self:longhand>
    // CSS 2.1, Section 13 - Paged media

    // CSS 2.1, Section 14 - Colors and Backgrounds

    ${new_style_struct("Background", is_inherited=False)}
    ${predefined_type("background-color", "CSSColor",
                      "RGBA(RGBA { red: 0., green: 0., blue: 0., alpha: 0. }) /* transparent */")}

    <%self:single_component_value name="background-image">
            // The computed value is the same as the specified value.
            pub use to_computed_value = super::computed_as_specified;
            pub mod computed_value {
                pub use url::Url;
                pub type T = Option<Url>;
            }
            pub type SpecifiedValue = computed_value::T;
            #[inline] pub fn get_initial_value() -> SpecifiedValue {
                None
            }
            pub fn from_component_value(component_value: &ComponentValue, base_url: &Url) -> Option<SpecifiedValue> {
                match component_value {
                    &ast::URL(ref url) => {
                        let image_url = parse_url(url.as_slice(), Some(base_url.clone()));
                        Some(Some(image_url))
                    },
                    &ast::Ident(ref value) if value.to_owned().eq_ignore_ascii_case("none") => Some(None),
                    _ => None,
                }
            }
    </%self:single_component_value>

    <%self:longhand name="background-position">
            use super::super::common_types::specified;

            pub mod computed_value {
                use super::super::super::common_types::computed::LengthOrPercentage;

                #[deriving(Eq, Clone)]
                pub struct T {
                    pub horizontal: LengthOrPercentage,
                    pub vertical: LengthOrPercentage,
                }
            }

            #[deriving(Clone)]
            pub struct SpecifiedValue {
                pub horizontal: specified::LengthOrPercentage,
                pub vertical: specified::LengthOrPercentage,
            }

            #[inline]
            pub fn to_computed_value(value: SpecifiedValue, context: &computed::Context)
                                     -> computed_value::T {
                computed_value::T {
                    horizontal: computed::compute_LengthOrPercentage(value.horizontal, context),
                    vertical: computed::compute_LengthOrPercentage(value.vertical, context),
                }
            }

            #[inline]
            pub fn get_initial_value() -> computed_value::T {
                computed_value::T {
                    horizontal: computed::LP_Percentage(0.0),
                    vertical: computed::LP_Percentage(0.0),
                }
            }

            // FIXME(#1997, pcwalton): Support complete CSS2 syntax.
            pub fn parse_horizontal_and_vertical(horiz: &ComponentValue, vert: &ComponentValue)
                                                 -> Option<SpecifiedValue> {
                let horiz = match specified::LengthOrPercentage::parse_non_negative(horiz) {
                    None => return None,
                    Some(value) => value,
                };

                let vert = match specified::LengthOrPercentage::parse_non_negative(vert) {
                    None => return None,
                    Some(value) => value,
                };

                Some(SpecifiedValue {
                    horizontal: horiz,
                    vertical: vert,
                })
            }

            pub fn parse(input: &[ComponentValue], _: &Url) -> Option<SpecifiedValue> {
                let mut input_iter = input.skip_whitespace();
                let horizontal = input_iter.next();
                let vertical = input_iter.next();
                if input_iter.next().is_some() {
                    return None
                }

                match (horizontal, vertical) {
                    (Some(horizontal), Some(vertical)) => {
                        parse_horizontal_and_vertical(horizontal, vertical)
                    }
                    _ => None
                }
            }
    </%self:longhand>

    ${single_keyword("background-repeat", "repeat repeat-x repeat-y no-repeat")}

    ${single_keyword("background-attachment", "scroll fixed")}

    ${new_style_struct("Color", is_inherited=True)}

    <%self:raw_longhand name="color">
        pub use to_computed_value = super::computed_as_specified;
        pub type SpecifiedValue = RGBA;
        pub mod computed_value {
            pub type T = super::SpecifiedValue;
        }
        #[inline] pub fn get_initial_value() -> computed_value::T {
            RGBA { red: 0., green: 0., blue: 0., alpha: 1. }  /* black */
        }
        pub fn parse_specified(input: &[ComponentValue], _base_url: &Url)
                               -> Option<DeclaredValue<SpecifiedValue>> {
            match one_component_value(input).and_then(Color::parse) {
                Some(RGBA(rgba)) => Some(SpecifiedValue(rgba)),
                Some(CurrentColor) => Some(CSSWideKeyword(Inherit)),
                None => None,
            }
        }
    </%self:raw_longhand>

    // CSS 2.1, Section 15 - Fonts

    ${new_style_struct("Font", is_inherited=True)}

    <%self:longhand name="font-family">
        pub use to_computed_value = super::computed_as_specified;
        pub mod computed_value {
            #[deriving(Eq, Clone)]
            pub enum FontFamily {
                FamilyName(~str),
                // Generic
//                Serif,
//                SansSerif,
//                Cursive,
//                Fantasy,
//                Monospace,
            }
            pub type T = Vec<FontFamily>;
        }
        pub type SpecifiedValue = computed_value::T;
        #[inline] pub fn get_initial_value() -> computed_value::T { vec!(FamilyName("serif".to_owned())) }
        /// <familiy-name>#
        /// <familiy-name> = <string> | [ <ident>+ ]
        /// TODO: <generic-familiy>
        pub fn parse(input: &[ComponentValue], _base_url: &Url) -> Option<SpecifiedValue> {
            from_iter(input.skip_whitespace())
        }
        pub fn from_iter<'a>(mut iter: SkipWhitespaceIterator<'a>) -> Option<SpecifiedValue> {
            let mut result = vec!();
            macro_rules! add(
                ($value: expr, $b: expr) => {
                    {
                        result.push($value);
                        match iter.next() {
                            Some(&Comma) => (),
                            None => $b,
                            _ => return None,
                        }
                    }
                }
            )
            'outer: loop {
                match iter.next() {
                    // TODO: avoid copying strings?
                    Some(&String(ref value)) => add!(FamilyName(value.to_owned()), break 'outer),
                    Some(&Ident(ref value)) => {
                        match value.to_owned().to_ascii_lower().as_slice() {
//                            "serif" => add!(Serif, break 'outer),
//                            "sans-serif" => add!(SansSerif, break 'outer),
//                            "cursive" => add!(Cursive, break 'outer),
//                            "fantasy" => add!(Fantasy, break 'outer),
//                            "monospace" => add!(Monospace, break 'outer),
                            _ => {
                                let mut idents = vec!(value.as_slice());
                                loop {
                                    match iter.next() {
                                        Some(&Ident(ref value)) => idents.push(value.as_slice()),
                                        Some(&Comma) => {
                                            result.push(FamilyName(idents.connect(" ")));
                                            break
                                        },
                                        None => {
                                            result.push(FamilyName(idents.connect(" ")));
                                            break 'outer
                                        },
                                        _ => return None,
                                    }
                                }
                            }
                        }
                    }
                    _ => return None,
                }
            }
            Some(result)
        }
    </%self:longhand>


    ${single_keyword("font-style", "normal italic oblique")}
    ${single_keyword("font-variant", "normal")}  // Add small-caps when supported

    <%self:single_component_value name="font-weight">
        #[deriving(Clone)]
        pub enum SpecifiedValue {
            Bolder,
            Lighter,
            % for weight in range(100, 901, 100):
                SpecifiedWeight${weight},
            % endfor
        }
        /// normal | bold | bolder | lighter | 100 | 200 | 300 | 400 | 500 | 600 | 700 | 800 | 900
        pub fn from_component_value(input: &ComponentValue, _base_url: &Url)
                                    -> Option<SpecifiedValue> {
            match input {
                &Ident(ref value) => {
                    match value.to_owned().to_ascii_lower().as_slice() {
                        "bold" => Some(SpecifiedWeight700),
                        "normal" => Some(SpecifiedWeight400),
                        "bolder" => Some(Bolder),
                        "lighter" => Some(Lighter),
                        _ => None,
                    }
                },
                &Number(ref value) => match value.int_value {
                    Some(100) => Some(SpecifiedWeight100),
                    Some(200) => Some(SpecifiedWeight200),
                    Some(300) => Some(SpecifiedWeight300),
                    Some(400) => Some(SpecifiedWeight400),
                    Some(500) => Some(SpecifiedWeight500),
                    Some(600) => Some(SpecifiedWeight600),
                    Some(700) => Some(SpecifiedWeight700),
                    Some(800) => Some(SpecifiedWeight800),
                    Some(900) => Some(SpecifiedWeight900),
                    _ => None,
                },
                _ => None
            }
        }
        pub mod computed_value {
            #[deriving(Eq, Clone)]
            pub enum T {
                % for weight in range(100, 901, 100):
                    Weight${weight},
                % endfor
            }
            impl T {
                pub fn is_bold(self) -> bool {
                    match self {
                        Weight900 | Weight800 | Weight700 | Weight600 => true,
                        _ => false
                    }
                }
            }
        }
        #[inline]
        pub fn get_initial_value() -> computed_value::T { Weight400 }  // normal
        #[inline]
        pub fn to_computed_value(value: SpecifiedValue, context: &computed::Context)
                              -> computed_value::T {
            match value {
                % for weight in range(100, 901, 100):
                    SpecifiedWeight${weight} => Weight${weight},
                % endfor
                Bolder => match context.inherited_font_weight {
                    Weight100 => Weight400,
                    Weight200 => Weight400,
                    Weight300 => Weight400,
                    Weight400 => Weight700,
                    Weight500 => Weight700,
                    Weight600 => Weight900,
                    Weight700 => Weight900,
                    Weight800 => Weight900,
                    Weight900 => Weight900,
                },
                Lighter => match context.inherited_font_weight {
                    Weight100 => Weight100,
                    Weight200 => Weight100,
                    Weight300 => Weight100,
                    Weight400 => Weight100,
                    Weight500 => Weight100,
                    Weight600 => Weight400,
                    Weight700 => Weight400,
                    Weight800 => Weight700,
                    Weight900 => Weight700,
                },
            }
        }
    </%self:single_component_value>

    <%self:single_component_value name="font-size">
        pub type SpecifiedValue = specified::Length;  // Percentages are the same as em.
        pub mod computed_value {
            use super::super::Au;
            pub type T = Au;
        }
        #[inline] pub fn get_initial_value() -> computed_value::T {
            Au::from_px(16)  // medium
        }
        #[inline]
        pub fn to_computed_value(_value: SpecifiedValue, context: &computed::Context)
                                 -> computed_value::T {
            // We already computed this element's font size; no need to compute it again.
            return context.font_size
        }
        /// <length> | <percentage>
        /// TODO: support <absolute-size> and <relative-size>
        pub fn from_component_value(input: &ComponentValue, _base_url: &Url)
                                    -> Option<SpecifiedValue> {
            specified::LengthOrPercentage::parse_non_negative(input).map(|value| {
                match value {
                    specified::LP_Length(value) => value,
                    specified::LP_Percentage(value) => specified::Em(value),
                }
            })
        }
    </%self:single_component_value>

    // CSS 2.1, Section 16 - Text

    ${new_style_struct("InheritedText", is_inherited=True)}

    // TODO: initial value should be 'start' (CSS Text Level 3, direction-dependent.)
    ${single_keyword("text-align", "left right center justify")}

    ${new_style_struct("Text", is_inherited=False)}

    <%self:longhand name="text-decoration">
        pub use to_computed_value = super::computed_as_specified;
        #[deriving(Eq, Clone)]
        pub struct SpecifiedValue {
            pub underline: bool,
            pub overline: bool,
            pub line_through: bool,
            // 'blink' is accepted in the parser but ignored.
            // Just not blinking the text is a conforming implementation per CSS 2.1.
        }
        pub mod computed_value {
            pub type T = super::SpecifiedValue;
            pub static none: T = super::SpecifiedValue { underline: false, overline: false, line_through: false };
        }
        #[inline] pub fn get_initial_value() -> computed_value::T {
            none
        }
        /// none | [ underline || overline || line-through || blink ]
        pub fn parse(input: &[ComponentValue], _base_url: &Url) -> Option<SpecifiedValue> {
            let mut result = SpecifiedValue {
                underline: false, overline: false, line_through: false,
            };
            let mut blink = false;
            let mut empty = true;
            for component_value in input.skip_whitespace() {
                match get_ident_lower(component_value) {
                    None => return None,
                    Some(keyword) => match keyword.as_slice() {
                        "underline" => if result.underline { return None }
                                      else { empty = false; result.underline = true },
                        "overline" => if result.overline { return None }
                                      else { empty = false; result.overline = true },
                        "line-through" => if result.line_through { return None }
                                          else { empty = false; result.line_through = true },
                        "blink" => if blink { return None }
                                   else { empty = false; blink = true },
                        "none" => return if empty { Some(result) } else { None },
                        _ => return None,
                    }
                }
            }
            if !empty { Some(result) } else { None }
        }
    </%self:longhand>

    ${switch_to_style_struct("InheritedText")}

    <%self:longhand name="-servo-text-decorations-in-effect"
                    derived_from="display text-decoration">
        use super::RGBA;
        use super::super::longhands::display;

        pub use to_computed_value = super::computed_as_specified;

        #[deriving(Clone, Eq)]
        pub struct SpecifiedValue {
            pub underline: Option<RGBA>,
            pub overline: Option<RGBA>,
            pub line_through: Option<RGBA>,
        }

        pub mod computed_value {
            pub type T = super::SpecifiedValue;
        }

        #[inline]
        pub fn get_initial_value() -> computed_value::T {
            SpecifiedValue {
                underline: None,
                overline: None,
                line_through: None,
            }
        }

        fn maybe(flag: bool, context: &computed::Context) -> Option<RGBA> {
            if flag {
                Some(context.color)
            } else {
                None
            }
        }

        fn derive(context: &computed::Context) -> computed_value::T {
            // Start with no declarations if this is a block; otherwise, start with the
            // declarations in effect and add in the text decorations that this inline specifies.
            let mut result = match context.display {
                display::computed_value::inline => context.inherited_text_decorations_in_effect,
                _ => {
                    SpecifiedValue {
                        underline: None,
                        overline: None,
                        line_through: None,
                    }
                }
            };

            if result.underline.is_none() {
                result.underline = maybe(context.text_decoration.underline, context)
            }
            if result.overline.is_none() {
                result.overline = maybe(context.text_decoration.overline, context)
            }
            if result.line_through.is_none() {
                result.line_through = maybe(context.text_decoration.line_through, context)
            }

            result
        }

        #[inline]
        pub fn derive_from_text_decoration(_: text_decoration::computed_value::T,
                                           context: &computed::Context)
                                           -> computed_value::T {
            derive(context)
        }

        #[inline]
        pub fn derive_from_display(_: display::computed_value::T, context: &computed::Context)
                                   -> computed_value::T {
            derive(context)
        }
    </%self:longhand>

    ${single_keyword("white-space", "normal pre")}

    // CSS 2.1, Section 17 - Tables
    ${new_style_struct("Table", is_inherited=False)}

    ${single_keyword("table-layout", "auto fixed")}

    // CSS 2.1, Section 18 - User interface
}


pub mod shorthands {
    pub use super::*;
    pub use super::longhands::*;

    <%def name="shorthand(name, sub_properties)">
    <%
        shorthand = Shorthand(name, sub_properties.split())
        SHORTHANDS.append(shorthand)
    %>
        pub mod ${shorthand.ident} {
            use super::*;
            pub struct Longhands {
                % for sub_property in shorthand.sub_properties:
                    pub ${sub_property.ident}: Option<${sub_property.ident}::SpecifiedValue>,
                % endfor
            }
            pub fn parse(input: &[ComponentValue], base_url: &Url) -> Option<Longhands> {
                ${caller.body()}
            }
        }
    </%def>

    <%def name="four_sides_shorthand(name, sub_property_pattern, parser_function)">
        <%self:shorthand name="${name}" sub_properties="${
                ' '.join(sub_property_pattern % side
                         for side in ['top', 'right', 'bottom', 'left'])}">
            let mut iter = input.skip_whitespace().map(|c| ${parser_function}(c, base_url));
            // zero or more than four values is invalid.
            // one value sets them all
            // two values set (top, bottom) and (left, right)
            // three values set top, (left, right) and bottom
            // four values set them in order
            let top = iter.next().unwrap_or(None);
            let right = iter.next().unwrap_or(top);
            let bottom = iter.next().unwrap_or(top);
            let left = iter.next().unwrap_or(right);
            if top.is_some() && right.is_some() && bottom.is_some() && left.is_some()
            && iter.next().is_none() {
                Some(Longhands {
                    % for side in ["top", "right", "bottom", "left"]:
                        ${to_rust_ident(sub_property_pattern % side)}: ${side},
                    % endfor
                })
            } else {
                None
            }
        </%self:shorthand>
    </%def>

    // TODO: other background-* properties
    <%self:shorthand name="background"
                     sub_properties="background-color background-position background-repeat background-attachment background-image">
                use std::mem;

                let (mut color, mut image, mut position, mut repeat, mut attachment) =
                    (None, None, None, None, None);
                let mut last_component_value = None;
                let mut any = false;

                for component_value in input.skip_whitespace() {
                    if color.is_none() {
                        match background_color::from_component_value(component_value, base_url) {
                            Some(v) => {
                                color = Some(v);
                                any = true;
                                continue
                            },
                            None => ()
                        }
                    }

                    if image.is_none() {
                        match background_image::from_component_value(component_value, base_url) {
                            Some(v) => {
                                image = Some(v);
                                any = true;
                                continue
                            },
                            None => (),
                        }
                    }

                    if repeat.is_none() {
                        match background_repeat::from_component_value(component_value, base_url) {
                            Some(v) => {
                                repeat = Some(v);
                                any = true;
                                continue
                            },
                            None => ()
                        }
                    }

                    if attachment.is_none() {
                        match background_attachment::from_component_value(component_value,
                                                                          base_url) {
                            Some(v) => {
                                attachment = Some(v);
                                any = true;
                                continue
                            },
                            None => ()
                        }
                    }

                    match mem::replace(&mut last_component_value, None) {
                        Some(saved_component_value) => {
                            if position.is_none() {
                                match background_position::parse_horizontal_and_vertical(
                                        saved_component_value,
                                        component_value) {
                                    Some(v) => {
                                        position = Some(v);
                                        any = true;
                                        continue
                                    },
                                    None => (),
                                }
                            }

                            // If we get here, parsing failed.
                            return None
                        }
                        None => {
                            // Save the component value.
                            last_component_value = Some(component_value)
                        }
                    }
                }

                if any && last_component_value.is_none() {
                    Some(Longhands {
                        background_color: color,
                        background_image: image,
                        background_position: position,
                        background_repeat: repeat,
                        background_attachment: attachment,
                    })
                } else {
                    None
                }
    </%self:shorthand>

    ${four_sides_shorthand("margin", "margin-%s", "margin_top::from_component_value")}
    ${four_sides_shorthand("padding", "padding-%s", "padding_top::from_component_value")}

    pub fn parse_color(value: &ComponentValue, _base_url: &Url) -> Option<specified::CSSColor> {
        specified::CSSColor::parse(value)
    }
    ${four_sides_shorthand("border-color", "border-%s-color", "parse_color")}
    ${four_sides_shorthand("border-style", "border-%s-style",
                           "border_top_style::from_component_value")}
    ${four_sides_shorthand("border-width", "border-%s-width", "parse_border_width")}

    pub fn parse_border(input: &[ComponentValue], base_url: &Url)
                     -> Option<(Option<specified::CSSColor>,
                                Option<border_top_style::SpecifiedValue>,
                                Option<specified::Length>)> {
        let mut color = None;
        let mut style = None;
        let mut width = None;
        let mut any = false;
        for component_value in input.skip_whitespace() {
            if color.is_none() {
                match specified::CSSColor::parse(component_value) {
                    Some(c) => { color = Some(c); any = true; continue },
                    None => ()
                }
            }
            if style.is_none() {
                match border_top_style::from_component_value(component_value, base_url) {
                    Some(s) => { style = Some(s); any = true; continue },
                    None => ()
                }
            }
            if width.is_none() {
                match parse_border_width(component_value, base_url) {
                    Some(w) => { width = Some(w); any = true; continue },
                    None => ()
                }
            }
            return None
        }
        if any { Some((color, style, width)) } else { None }
    }


    % for side in ["top", "right", "bottom", "left"]:
        <%self:shorthand name="border-${side}" sub_properties="${' '.join(
            'border-%s-%s' % (side, prop)
            for prop in ['color', 'style', 'width']
        )}">
            parse_border(input, base_url).map(|(color, style, width)| {
                Longhands {
                    % for prop in ["color", "style", "width"]:
                        ${"border_%s_%s: %s," % (side, prop, prop)}
                    % endfor
                }
            })
        </%self:shorthand>
    % endfor

    <%self:shorthand name="border" sub_properties="${' '.join(
        'border-%s-%s' % (side, prop)
        for side in ['top', 'right', 'bottom', 'left']
        for prop in ['color', 'style', 'width']
    )}">
        parse_border(input, base_url).map(|(color, style, width)| {
            Longhands {
                % for side in ["top", "right", "bottom", "left"]:
                    % for prop in ["color", "style", "width"]:
                        ${"border_%s_%s: %s," % (side, prop, prop)}
                    % endfor
                % endfor
            }
        })
    </%self:shorthand>

    <%self:shorthand name="font" sub_properties="font-style font-variant font-weight
                                                 font-size line-height font-family">
        let mut iter = input.skip_whitespace();
        let mut nb_normals = 0u;
        let mut style = None;
        let mut variant = None;
        let mut weight = None;
        let mut size = None;
        let mut line_height = None;
        for component_value in iter {
            // Special-case 'normal' because it is valid in each of
            // font-style, font-weight and font-variant.
            // Leaves the values to None, 'normal' is the initial value for each of them.
            match get_ident_lower(component_value) {
                Some(ref ident) if ident.to_owned().eq_ignore_ascii_case("normal") => {
                    nb_normals += 1;
                    continue;
                }
                _ => {}
            }
            if style.is_none() {
                match font_style::from_component_value(component_value, base_url) {
                    Some(s) => { style = Some(s); continue },
                    None => ()
                }
            }
            if weight.is_none() {
                match font_weight::from_component_value(component_value, base_url) {
                    Some(w) => { weight = Some(w); continue },
                    None => ()
                }
            }
            if variant.is_none() {
                match font_variant::from_component_value(component_value, base_url) {
                    Some(v) => { variant = Some(v); continue },
                    None => ()
                }
            }
            match font_size::from_component_value(component_value, base_url) {
                Some(s) => { size = Some(s); break },
                None => return None
            }
        }
        #[inline]
        fn count<T>(opt: &Option<T>) -> uint {
            match opt {
                &Some(_) => 1,
                &None => 0,
            }
        }
        if size.is_none() || (count(&style) + count(&weight) + count(&variant) + nb_normals) > 3 {
            return None
        }
        let mut copied_iter = iter.clone();
        match copied_iter.next() {
            Some(&Delim('/')) => {
                iter = copied_iter;
                line_height = match iter.next() {
                    Some(v) => line_height::from_component_value(v, base_url),
                    _ => return None,
                };
                if line_height.is_none() { return None }
            }
            _ => ()
        }
        let family = font_family::from_iter(iter);
        if family.is_none() { return None }
        Some(Longhands {
            font_style: style,
            font_variant: variant,
            font_weight: weight,
            font_size: size,
            line_height: line_height,
            font_family: family
        })
    </%self:shorthand>

}


// TODO(SimonSapin): Convert this to a syntax extension rather than a Mako template.
// Maybe submit for inclusion in libstd?
mod property_bit_field {
    use std::uint;
    use std::mem;

    pub struct PropertyBitField {
        storage: [uint, ..(${len(LONGHANDS)} - 1 + uint::BITS) / uint::BITS]
    }

    impl PropertyBitField {
        #[inline]
        pub fn new() -> PropertyBitField {
            PropertyBitField { storage: unsafe { mem::init() } }
        }

        #[inline]
        fn get(&self, bit: uint) -> bool {
            (self.storage[bit / uint::BITS] & (1 << (bit % uint::BITS))) != 0
        }
        #[inline]
        fn set(&mut self, bit: uint) {
            self.storage[bit / uint::BITS] |= 1 << (bit % uint::BITS)
        }
        #[inline]
        fn clear(&mut self, bit: uint) {
            self.storage[bit / uint::BITS] &= !(1 << (bit % uint::BITS))
        }
        % for i, property in enumerate(LONGHANDS):
            #[inline]
            pub fn get_${property.ident}(&self) -> bool {
                self.get(${i})
            }
            #[inline]
            pub fn set_${property.ident}(&mut self) {
                self.set(${i})
            }
            #[inline]
            pub fn clear_${property.ident}(&mut self) {
                self.clear(${i})
            }
        % endfor
    }
}


/// Declarations are stored in reverse order.
/// Overridden declarations are skipped.
pub struct PropertyDeclarationBlock {
    pub important: Arc<Vec<PropertyDeclaration>>,
    pub normal: Arc<Vec<PropertyDeclaration>>,
}

impl<E, S: Encoder<E>> Encodable<S, E> for PropertyDeclarationBlock {
    fn encode(&self, _: &mut S) -> Result<(), E> {
        Ok(())
    }
}


pub fn parse_style_attribute(input: &str, base_url: &Url) -> PropertyDeclarationBlock {
    parse_property_declaration_list(tokenize(input), base_url)
}


pub fn parse_property_declaration_list<I: Iterator<Node>>(input: I, base_url: &Url) -> PropertyDeclarationBlock {
    let mut important_declarations = vec!();
    let mut normal_declarations = vec!();
    let mut important_seen = PropertyBitField::new();
    let mut normal_seen = PropertyBitField::new();
    let items: Vec<DeclarationListItem> =
        ErrorLoggerIterator(parse_declaration_list(input)).collect();
    for item in items.move_iter().rev() {
        match item {
            DeclAtRule(rule) => log_css_error(
                rule.location, format!("Unsupported at-rule in declaration list: @{:s}", rule.name)),
            Declaration(Declaration{ location: l, name: n, value: v, important: i}) => {
                // TODO: only keep the last valid declaration for a given name.
                let (list, seen) = if i {
                    (&mut important_declarations, &mut important_seen)
                } else {
                    (&mut normal_declarations, &mut normal_seen)
                };
                match PropertyDeclaration::parse(n.to_owned(), v.as_slice(), list, base_url, seen) {
                    UnknownProperty => log_css_error(l, format!(
                        "Unsupported property: {}:{}", n, v.iter().to_css())),
                    InvalidValue => log_css_error(l, format!(
                        "Invalid value: {}:{}", n, v.iter().to_css())),
                    ValidOrIgnoredDeclaration => (),
                }
            }
        }
    }
    PropertyDeclarationBlock {
        important: Arc::new(important_declarations),
        normal: Arc::new(normal_declarations),
    }
}


#[deriving(Clone)]
pub enum CSSWideKeyword {
    Initial,
    Inherit,
}

impl CSSWideKeyword {
    pub fn parse(input: &[ComponentValue]) -> Option<Option<CSSWideKeyword>> {
        one_component_value(input).and_then(get_ident_lower).and_then(|keyword| {
            match keyword.as_slice() {
                "initial" => Some(Some(Initial)),
                "inherit" => Some(Some(Inherit)),
                "unset" => Some(None),
                _ => None
            }
        })
    }
}


#[deriving(Clone)]
pub enum DeclaredValue<T> {
    SpecifiedValue(T),
    CSSWideKeyword(CSSWideKeyword),
}

#[deriving(Clone)]
pub enum PropertyDeclaration {
    % for property in LONGHANDS:
        ${property.camel_case}Declaration(DeclaredValue<longhands::${property.ident}::SpecifiedValue>),
    % endfor
}


pub enum PropertyDeclarationParseResult {
    UnknownProperty,
    InvalidValue,
    ValidOrIgnoredDeclaration,
}


impl PropertyDeclaration {
    pub fn parse(name: &str, value: &[ComponentValue],
                 result_list: &mut Vec<PropertyDeclaration>,
                 base_url: &Url,
                 seen: &mut PropertyBitField) -> PropertyDeclarationParseResult {
        // FIXME: local variable to work around Rust #10683
        let name_lower = name.to_owned().to_ascii_lower();
        match name_lower.as_slice() {
            % for property in LONGHANDS:
                % if property.derived_from is None:
                    "${property.name}" => {
                        if seen.get_${property.ident}() {
                            return ValidOrIgnoredDeclaration
                        }
                        match longhands::${property.ident}::parse_declared(value, base_url) {
                            Some(value) => {
                                seen.set_${property.ident}();
                                result_list.push(${property.camel_case}Declaration(value));
                                ValidOrIgnoredDeclaration
                            },
                            None => InvalidValue,
                        }
                    },
                % else:
                    "${property.name}" => UnknownProperty,
                % endif
            % endfor
            % for shorthand in SHORTHANDS:
                "${shorthand.name}" => {
                    if ${" && ".join("seen.get_%s()" % sub_property.ident
                                     for sub_property in shorthand.sub_properties)} {
                        return ValidOrIgnoredDeclaration
                    }
                    match CSSWideKeyword::parse(value) {
                        Some(Some(keyword)) => {
                            % for sub_property in shorthand.sub_properties:
                                if !seen.get_${sub_property.ident}() {
                                    seen.set_${sub_property.ident}();
                                    result_list.push(${sub_property.camel_case}Declaration(
                                        CSSWideKeyword(keyword)));
                                }
                            % endfor
                            ValidOrIgnoredDeclaration
                        },
                        Some(None) => {
                            % for sub_property in shorthand.sub_properties:
                                if !seen.get_${sub_property.ident}() {
                                    seen.set_${sub_property.ident}();
                                    result_list.push(${sub_property.camel_case}Declaration(
                                        CSSWideKeyword(
                                            ${"Inherit" if sub_property.style_struct.inherited else "Initial"}
                                        )
                                    ));
                                }
                            % endfor
                            ValidOrIgnoredDeclaration
                        },
                        None => match shorthands::${shorthand.ident}::parse(value, base_url) {
                            Some(result) => {
                                % for sub_property in shorthand.sub_properties:
                                    if !seen.get_${sub_property.ident}() {
                                        seen.set_${sub_property.ident}();
                                        result_list.push(${sub_property.camel_case}Declaration(
                                            match result.${sub_property.ident} {
                                                Some(value) => SpecifiedValue(value),
                                                None => CSSWideKeyword(Initial),
                                            }
                                        ));
                                    }
                                % endfor
                                ValidOrIgnoredDeclaration
                            },
                            None => InvalidValue,
                        }
                    }
                },
            % endfor
            _ => UnknownProperty,
        }
    }
}


pub mod style_structs {
    use super::longhands;
    % for style_struct in STYLE_STRUCTS:
        #[deriving(Eq, Clone)]
        pub struct ${style_struct.name} {
            % for longhand in style_struct.longhands:
                pub ${longhand.ident}: longhands::${longhand.ident}::computed_value::T,
            % endfor
        }
    % endfor
}

#[deriving(Clone)]
pub struct ComputedValues {
    % for style_struct in STYLE_STRUCTS:
        ${style_struct.ident}: Arc<style_structs::${style_struct.name}>,
    % endfor
    shareable: bool,
}

impl ComputedValues {
    /// Resolves the currentColor keyword.
    /// Any color value form computed values (except for the 'color' property itself)
    /// should go through this method.
    ///
    /// Usage example:
    /// let top_color = style.resolve_color(style.Border.border_top_color);
    #[inline]
    pub fn resolve_color(&self, color: computed::CSSColor) -> RGBA {
        match color {
            RGBA(rgba) => rgba,
            CurrentColor => self.get_color().color,
        }
    }

    % for style_struct in STYLE_STRUCTS:
        pub fn get_${style_struct.name.lower()}
                <'a>(&'a self) -> &'a style_structs::${style_struct.name} {
            &*self.${style_struct.ident}
        }
    % endfor
}

/// The initial values for all style structs as defined by the specification.
lazy_init! {
    static ref INITIAL_VALUES: ComputedValues = ComputedValues {
        % for style_struct in STYLE_STRUCTS:
            ${style_struct.ident}: Arc::new(style_structs::${style_struct.name} {
                % for longhand in style_struct.longhands:
                    ${longhand.ident}: longhands::${longhand.ident}::get_initial_value(),
                % endfor
            }),
        % endfor
        shareable: true,
    };
}


/// This only exists to limit the scope of #[allow(experimental)]
/// FIXME: remove this when Arc::make_unique() is not experimental anymore.
trait ArcExperimental<T> {
    fn make_unique_experimental<'a>(&'a mut self) -> &'a mut T;
}
impl<T: Send + Share + Clone> ArcExperimental<T> for Arc<T> {
    #[inline]
    #[allow(experimental)]
    fn make_unique_experimental<'a>(&'a mut self) -> &'a mut T {
        self.make_unique()
    }
}

/// Fast path for the function below. Only computes new inherited styles.
fn cascade_with_cached_declarations(applicable_declarations: &[MatchedProperty],
                                    shareable: bool,
                                    parent_style: &ComputedValues,
                                    cached_style: &ComputedValues,
                                    context: &computed::Context)
                                    -> ComputedValues {
    % for style_struct in STYLE_STRUCTS:
        % if style_struct.inherited:
            let mut style_${style_struct.ident} = parent_style.${style_struct.ident}.clone();
        % else:
            let style_${style_struct.ident} = cached_style.${style_struct.ident}.clone();
        % endif
    % endfor

    let mut seen = PropertyBitField::new();
    // Declaration blocks are stored in increasing precedence order,
    // we want them in decreasing order here.
    for sub_list in applicable_declarations.iter().rev() {
        // Declarations are already stored in reverse order.
        for declaration in sub_list.declarations.iter() {
            match *declaration {
                % for style_struct in STYLE_STRUCTS:
                    % if style_struct.inherited:
                        % for property in style_struct.longhands:
                            % if property.derived_from is None:
                                ${property.camel_case}Declaration(ref declared_value) => {
                                    if seen.get_${property.ident}() {
                                        continue
                                    }
                                    seen.set_${property.ident}();
                                    let computed_value = match *declared_value {
                                        SpecifiedValue(ref specified_value)
                                        => longhands::${property.ident}::to_computed_value(
                                            (*specified_value).clone(),
                                            context
                                        ),
                                        CSSWideKeyword(Initial)
                                        => longhands::${property.ident}::get_initial_value(),
                                        CSSWideKeyword(Inherit) => {
                                            // This is a bit slow, but this is rare so it shouldn't
                                            // matter.
                                            //
                                            // FIXME: is it still?
                                            parent_style.${style_struct.ident}
                                                        .${property.ident}
                                                        .clone()
                                        }
                                    };
                                    style_${style_struct.ident}.make_unique_experimental()
                                        .${property.ident} = computed_value;

                                    % if property.name in DERIVED_LONGHANDS:
                                        % for derived in DERIVED_LONGHANDS[property.name]:
                                            style_${derived.style_struct.ident}
                                                .make_unique_experimental()
                                                .${derived.ident} =
                                                longhands::${derived.ident}
                                                         ::derive_from_${property.ident}(
                                                             computed_value,
                                                             context);
                                        % endfor
                                    % endif
                                }
                            % else:
                                ${property.camel_case}Declaration(_) => {
                                    // Do not allow stylesheets to set derived properties.
                                }
                            % endif
                        % endfor
                    % endif
                % endfor
                _ => {}
            }
        }
    }

    ComputedValues {
        % for style_struct in STYLE_STRUCTS:
            ${style_struct.ident}: style_${style_struct.ident},
        % endfor
        shareable: shareable,
    }
}

/// Performs the CSS cascade, computing new styles for an element from its parent style and
/// optionally a cached related style. The arguments are:
///
///   * `applicable_declarations`: The list of CSS rules that matched.
///
///   * `shareable`: Whether the `ComputedValues` structure to be constructed should be considered
///     shareable.
///
///   * `parent_style`: The parent style, if applicable; if `None`, this is the root node.
///
///   * `cached_style`: If present, cascading is short-circuited for everything but inherited
///     values and these values are used instead. Obviously, you must be careful when supplying
///     this that it is safe to only provide inherited declarations. If `parent_style` is `None`,
///     this is ignored.
///
/// Returns the computed values and a boolean indicating whether the result is cacheable.
pub fn cascade(applicable_declarations: &[MatchedProperty],
               shareable: bool,
               parent_style: Option< &ComputedValues >,
               cached_style: Option< &ComputedValues >)
               -> (ComputedValues, bool) {
    let initial_values = &*INITIAL_VALUES;
    let (is_root_element, inherited_style) = match parent_style {
        Some(parent_style) => (false, parent_style),
        None => (true, initial_values),
    };

    let mut context = {
        let inherited_font_style = inherited_style.get_font();
        computed::Context {
            is_root_element: is_root_element,
            inherited_font_weight: inherited_font_style.font_weight,
            inherited_font_size: inherited_font_style.font_size,
            inherited_height: inherited_style.get_box().height,
            inherited_minimum_line_height: inherited_style.get_inheritedbox()
                                                          ._servo_minimum_line_height,
            inherited_text_decorations_in_effect:
                inherited_style.get_inheritedtext()._servo_text_decorations_in_effect,
            // To be overridden by applicable declarations:
            font_size: inherited_font_style.font_size,
            display: longhands::display::get_initial_value(),
            color: inherited_style.get_color().color,
            text_decoration: longhands::text_decoration::get_initial_value(),
            positioned: false,
            floated: false,
            border_top_present: false,
            border_right_present: false,
            border_bottom_present: false,
            border_left_present: false,
        }
    };

    // This assumes that the computed and specified values have the same Rust type.
    macro_rules! get_specified(
        ($style_struct_getter: ident, $property: ident, $declared_value: expr) => {
            match *$declared_value {
                SpecifiedValue(specified_value) => specified_value,
                CSSWideKeyword(Initial) => longhands::$property::get_initial_value(),
                CSSWideKeyword(Inherit) => inherited_style.$style_struct_getter().$property.clone(),
            }
        };
    )

    // Initialize `context`
    // Declarations blocks are already stored in increasing precedence order.
    for sub_list in applicable_declarations.iter() {
        // Declarations are stored in reverse source order, we want them in forward order here.
        for declaration in sub_list.declarations.iter().rev() {
            match *declaration {
                FontSizeDeclaration(ref value) => {
                    context.font_size = match *value {
                        SpecifiedValue(specified_value) => computed::compute_Au_with_font_size(
                            specified_value, context.inherited_font_size),
                        CSSWideKeyword(Initial) => longhands::font_size::get_initial_value(),
                        CSSWideKeyword(Inherit) => context.inherited_font_size,
                    }
                }
                ColorDeclaration(ref value) => {
                    context.color = get_specified!(get_color, color, value);
                }
                DisplayDeclaration(ref value) => {
                    context.display = get_specified!(get_box, display, value);
                }
                PositionDeclaration(ref value) => {
                    context.positioned = match get_specified!(get_box, position, value) {
                        longhands::position::absolute | longhands::position::fixed => true,
                        _ => false,
                    }
                }
                FloatDeclaration(ref value) => {
                    context.floated = get_specified!(get_box, float, value)
                                      != longhands::float::none;
                }
                TextDecorationDeclaration(ref value) => {
                    context.text_decoration = get_specified!(get_text, text_decoration, value);
                }
                % for side in ["top", "right", "bottom", "left"]:
                    Border${side.capitalize()}StyleDeclaration(ref value) => {
                        context.border_${side}_present =
                        match get_specified!(get_border, border_${side}_style, value) {
                            longhands::border_top_style::none |
                            longhands::border_top_style::hidden => false,
                            _ => true,
                        };
                    }
                % endfor
                _ => {}
            }
        }
    }

    match (cached_style, parent_style) {
        (Some(cached_style), Some(parent_style)) => {
            return (cascade_with_cached_declarations(applicable_declarations,
                                                     shareable,
                                                     parent_style,
                                                     cached_style,
                                                     &context), false)
        }
        (_, _) => {}
    }

    // Set computed values, overwriting earlier declarations for the same property.
    % for style_struct in STYLE_STRUCTS:
        let mut style_${style_struct.ident} =
            % if style_struct.inherited:
                inherited_style
            % else:
                initial_values
            % endif
            .${style_struct.ident}.clone();
    % endfor
    let mut cacheable = true;
    let mut seen = PropertyBitField::new();
    // Declaration blocks are stored in increasing precedence order,
    // we want them in decreasing order here.
    for sub_list in applicable_declarations.iter().rev() {
        // Declarations are already stored in reverse order.
        for declaration in sub_list.declarations.iter() {
            match *declaration {
                % for style_struct in STYLE_STRUCTS:
                    % for property in style_struct.longhands:
                        % if property.derived_from is None:
                            ${property.camel_case}Declaration(ref declared_value) => {
                                if seen.get_${property.ident}() {
                                    continue
                                }
                                seen.set_${property.ident}();
                                let computed_value = match *declared_value {
                                    SpecifiedValue(ref specified_value)
                                    => longhands::${property.ident}::to_computed_value(
                                        (*specified_value).clone(),
                                        &context
                                    ),
                                    CSSWideKeyword(Initial)
                                    => longhands::${property.ident}::get_initial_value(),
                                    CSSWideKeyword(Inherit) => {
                                        // This is a bit slow, but this is rare so it shouldn't
                                        // matter.
                                        //
                                        // FIXME: is it still?
                                        cacheable = false;
                                        inherited_style.${style_struct.ident}
                                                       .${property.ident}
                                                       .clone()
                                    }
                                };
                                style_${style_struct.ident}.make_unique_experimental()
                                    .${property.ident} = computed_value;

                                % if property.name in DERIVED_LONGHANDS:
                                    % for derived in DERIVED_LONGHANDS[property.name]:
                                        style_${derived.style_struct.ident}
                                            .make_unique_experimental()
                                            .${derived.ident} =
                                            longhands::${derived.ident}
                                                     ::derive_from_${property.ident}(
                                                         computed_value,
                                                         &context);
                                    % endfor
                                % endif
                            }
                        % else:
                            ${property.camel_case}Declaration(_) => {
                                // Do not allow stylesheets to set derived properties.
                            }
                        % endif
                    % endfor
                % endfor
            }
        }
    }

    // The initial value of border-*-width may be changed at computed value time.
    {
        let border = style_border.make_unique_experimental();
        % for side in ["top", "right", "bottom", "left"]:
            // Like calling to_computed_value, which wouldn't type check.
            if !context.border_${side}_present {
                border.border_${side}_width = Au(0);
            }
        % endfor
    }

    // The initial value of display may be changed at computed value time.
    if !seen.get_display() {
        let box_ = style_box_.make_unique_experimental();
        box_.display = longhands::display::to_computed_value(box_.display, &context);
    }

    (ComputedValues {
        % for style_struct in STYLE_STRUCTS:
            ${style_struct.ident}: style_${style_struct.ident},
        % endfor
        shareable: shareable,
    }, cacheable)
}


/// Equivalent to `cascade()` with an empty `applicable_declarations`
/// Performs the CSS cascade for an anonymous box.
///
///   * `parent_style`: Computed style of the element this anonymous box inherits from.
pub fn cascade_anonymous(parent_style: &ComputedValues) -> ComputedValues {
    let initial_values = &*INITIAL_VALUES;
    let mut result = ComputedValues {
        % for style_struct in STYLE_STRUCTS:
            ${style_struct.ident}:
                % if style_struct.inherited:
                    parent_style
                % else:
                    initial_values
                % endif
                .${style_struct.ident}.clone(),
        % endfor
        shareable: false,
    };
    {
        let border = result.border.make_unique_experimental();
        % for side in ["top", "right", "bottom", "left"]:
            // Like calling to_computed_value, which wouldn't type check.
            border.border_${side}_width = Au(0);
        % endfor
    }
    // None of the teaks on 'display' apply here.
    result
}


// Only re-export the types for computed values.
pub mod computed_values {
    % for property in LONGHANDS:
        pub use ${property.ident} = super::longhands::${property.ident}::computed_value;
    % endfor
    // Don't use a side-specific name needlessly:
    pub use border_style = super::longhands::border_top_style::computed_value;

    pub use cssparser::RGBA;
    pub use super::common_types::computed::{
        LengthOrPercentage, LP_Length, LP_Percentage,
        LengthOrPercentageOrAuto, LPA_Length, LPA_Percentage, LPA_Auto,
        LengthOrPercentageOrNone, LPN_Length, LPN_Percentage, LPN_None};
}
